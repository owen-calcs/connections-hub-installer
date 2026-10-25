<#
.SYNOPSIS
Sets up the HSS Connections Hub API key and the Connections Hub MCP server on Windows.

.DESCRIPTION
1. Checks the key against the API (skip with -SkipVerify).
2. Saves the key as the user environment variable HUB_API_KEY, for the REST API
   (curl, scripts, Codex, Gemini CLI).
3. Adds the "connectionshub" MCP server to each tool it finds:
   Claude Code, Claude Desktop, Cursor, VS Code, Windsurf, Antigravity, Codex, Gemini CLI

Existing config files are backed up as <file>.bak-<timestamp> before they change.
A file that is not plain JSON (for example VS Code settings with comments) is left
alone and reported.

.PARAMETER ApiKey
Your Connections Hub API key. If you leave it out, the script asks for it.

.PARAMETER Detect
List the tools it finds and change nothing.

.EXAMPLE
.\install-connections-hub.ps1 YOUR_API_KEY

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\install-connections-hub.ps1 YOUR_API_KEY
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$ApiKey,
    [switch]$Detect,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$McpUrl  = 'https://api.calcs.com/mcp'
$ApiUrl  = 'https://api.calcs.com/v1/projects'
$EnvName = 'HUB_API_KEY'
$Stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$Utf8    = New-Object System.Text.UTF8Encoding($false)   # no BOM, some tools choke on one

function Write-Ok($m)   { Write-Host "  [ok] $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Write-Fail($m) { Write-Host "  [x]  $m" -ForegroundColor Red }
function Write-Dim($m)  { Write-Host "  $m" -ForegroundColor DarkGray }

# ---------------------------------------------------------------- detection

$Home_   = $env:USERPROFILE
$AppData = $env:APPDATA
$Local   = $env:LOCALAPPDATA

function Test-Cmd($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

$ClaudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if (-not $ClaudeCmd) {
    foreach ($p in @("$Home_\.local\bin\claude.exe", "$Home_\.claude\local\claude.exe", "$AppData\npm\claude.cmd")) {
        if (Test-Path -LiteralPath $p) { $ClaudeCmd = Get-Item -LiteralPath $p; break }
    }
}
$ClaudeBin = if ($ClaudeCmd) { if ($ClaudeCmd.Source) { $ClaudeCmd.Source } else { $ClaudeCmd.FullName } } else { $null }

# Claude Desktop from the Microsoft Store keeps its config in a Packages folder.
$DesktopDir = "$AppData\Claude"
$storeDir = Get-ChildItem "$Local\Packages" -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($storeDir -and (Test-Path -LiteralPath "$($storeDir.FullName)\LocalCache\Roaming\Claude")) {
    $DesktopDir = "$($storeDir.FullName)\LocalCache\Roaming\Claude"
}

$Clients = [ordered]@{}
if ($ClaudeBin -or (Test-Path "$Home_\.claude"))                                  { $Clients['claude-code'] = 'Claude Code' }
if ((Test-Path $DesktopDir) -or (Test-Path "$Local\AnthropicClaude") -or $storeDir) { $Clients['claude-desktop'] = 'Claude Desktop' }
if ((Test-Path "$Local\Programs\cursor") -or (Test-Cmd cursor) -or (Test-Path "$Home_\.cursor")) { $Clients['cursor'] = 'Cursor' }
if ((Test-Path "$Local\Programs\Microsoft VS Code") -or (Test-Cmd code) -or (Test-Path "$AppData\Code\User")) { $Clients['vscode'] = 'VS Code (GitHub Copilot)' }
if ((Test-Path "$Local\Programs\Windsurf") -or (Test-Cmd windsurf) -or (Test-Path "$Home_\.codeium\windsurf")) { $Clients['windsurf'] = 'Windsurf' }
if ((Test-Path "$Local\Programs\Antigravity") -or (Test-Cmd antigravity) -or (Test-Path "$Home_\.gemini\antigravity") -or (Test-Path "$Home_\.antigravity")) { $Clients['antigravity'] = 'Antigravity' }
if ((Test-Cmd codex) -or (Test-Path "$Home_\.codex"))                             { $Clients['codex'] = 'Codex' }
if ((Test-Cmd gemini) -or (Test-Path "$Home_\.gemini\settings.json"))                           { $Clients['gemini'] = 'Gemini CLI' }

Write-Host 'Detected tools:'
if ($Clients.Count -eq 0) { Write-Dim 'none found' } else { foreach ($v in $Clients.Values) { Write-Ok $v } }
if ($Detect) { return }

# ---------------------------------------------------------------- the key

if (-not $ApiKey) {
    $secure = Read-Host 'Paste your Connections Hub API key and press Enter (right-click pastes here, you will see * as it goes in)' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
# Accept a pasted "Bearer xxx", quotes, or stray whitespace.
$Key = ($ApiKey -replace '^\s*Bearer\s+', '') -replace '[\s"'']', ''
if (-not $Key) { Write-Fail 'No API key given. Usage: .\install-connections-hub.ps1 YOUR_API_KEY'; exit 1 }

Write-Host "`nChecking the key:"
if ($SkipVerify) {
    Write-Dim 'skipped'
} else {
    try {
        $null = Invoke-WebRequest -Uri $ApiUrl -Headers @{ Authorization = "Bearer $Key" } -UseBasicParsing -TimeoutSec 15
        Write-Ok 'API accepted the key'
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -eq 401 -or $status -eq 403) {
            Write-Fail "API rejected the key (HTTP $status). Check you copied all of it."
            exit 1
        } elseif ($status) {
            Write-Warn "API answered HTTP $status, carrying on"
        } else {
            Write-Warn 'Could not reach api.calcs.com, carrying on without checking the key'
        }
    }
}

# ---------------------------------------------------------------- helpers

$Done = New-Object System.Collections.Generic.List[string]
$Problems = New-Object System.Collections.Generic.List[string]
$Notes = New-Object System.Collections.Generic.List[string]

function Backup-File($path) {
    if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination "$path.bak-$Stamp" -Force }
}
function Remove-BackupIfSame($path) {
    $bak = "$path.bak-$Stamp"
    if ((Test-Path -LiteralPath $bak) -and ((Get-Content -LiteralPath $path -Raw) -ceq (Get-Content -LiteralPath $bak -Raw))) {
        Remove-Item -LiteralPath $bak -Force
    }
}
function Write-Text($path, $text) {
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($path, $text, $Utf8)
}

function Read-JsonObject($path) {
    if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{} }
    $text = Get-Content -LiteralPath $path -Raw
    if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{} }
    try { $obj = $text | ConvertFrom-Json } catch { throw 'file is not plain JSON (comments or a syntax error)' }
    if ($obj -isnot [pscustomobject]) { throw 'file is not a JSON object' }
    return $obj
}
function Set-Prop($obj, $name, $value) {
    if ($obj.PSObject.Properties[$name]) { $obj.$name = $value }
    else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}
# Returns $obj.$name as a JSON object, creating it if it is missing or the wrong type.
function Get-Section($obj, $name) {
    $cur = $obj.PSObject.Properties[$name]
    if (-not $cur -or $cur.Value -isnot [pscustomobject]) { Set-Prop $obj $name ([pscustomobject]@{}) }
    return $obj.$name
}

# Edits one JSON config file. Nothing is written unless the existing file parses.
function Update-JsonConfig($path, $kind) {
    $obj = Read-JsonObject $path
    $bearer = "Bearer $Key"
    switch ($kind) {
        'cursor' {
            Set-Prop (Get-Section $obj 'mcpServers') 'connectionshub' ([ordered]@{ url = $McpUrl; headers = [ordered]@{ Authorization = $bearer } })
        }
        { $_ -in 'windsurf', 'antigravity' } {
            Set-Prop (Get-Section $obj 'mcpServers') 'connectionshub' ([ordered]@{ serverUrl = $McpUrl; headers = [ordered]@{ Authorization = $bearer } })
        }
        'desktop' {
            Set-Prop (Get-Section $obj 'mcpServers') 'connectionshub' ([ordered]@{
                command = 'npx'
                args    = @('-y', 'mcp-remote', $McpUrl, '--header', 'Authorization:${HUB_AUTH}')
                env     = [ordered]@{ HUB_AUTH = $bearer }
            })
        }
        'gemini' {
            Set-Prop (Get-Section $obj 'mcpServers') 'connectionshub' ([ordered]@{ httpUrl = $McpUrl; headers = [ordered]@{ Authorization = 'Bearer $HUB_API_KEY' } })
        }
        'vscode' {
            $keyInput = [ordered]@{ type = 'promptString'; id = 'connectionshub-api-key'; description = 'Connections Hub API key'; password = $true }
            $rest = @()
            if ($obj.PSObject.Properties['inputs'] -and $obj.inputs -is [array]) {
                $rest = @($obj.inputs | Where-Object { -not $_ -or $_.id -ne 'connectionshub-api-key' })
            }
            Set-Prop $obj 'inputs' ([object[]]($rest + @($keyInput)))
            Set-Prop (Get-Section $obj 'servers') 'connectionshub' ([ordered]@{ type = 'http'; url = $McpUrl; headers = [ordered]@{ Authorization = 'Bearer ${input:connectionshub-api-key}' } })
        }
        'claude-settings' {
            $envSec = Get-Section $obj 'env'
            $cur = 0
            if ($envSec.PSObject.Properties['MAX_MCP_OUTPUT_TOKENS']) { [int]::TryParse([string]$envSec.MAX_MCP_OUTPUT_TOKENS, [ref]$cur) | Out-Null }
            if ($cur -lt 100000) { Set-Prop $envSec 'MAX_MCP_OUTPUT_TOKENS' '100000' }
        }
        default { throw "unknown kind $kind" }
    }
    Backup-File $path
    Write-Text $path (($obj | ConvertTo-Json -Depth 20) + "`n")
    Remove-BackupIfSame $path
}

function Invoke-Step($id, $action) {
    Write-Host $Clients[$id]
    try { & $action; $Done.Add($Clients[$id]) }
    catch { Write-Fail "$($_.Exception.Message)"; $Problems.Add($Clients[$id]) }
}

# ---------------------------------------------------------------- the API key (HUB_API_KEY)

Write-Host "`nSaving the API key as ${EnvName}:"
try {
    [Environment]::SetEnvironmentVariable($EnvName, $Key, 'User')   # persists, and new windows and apps see it
    Set-Item -Path "Env:$EnvName" -Value $Key                        # this window too
    Write-Ok "user environment variable $EnvName"
    $Notes.Add("Open a new terminal window so $EnvName is set there.")
} catch {
    Write-Fail "Could not set $EnvName : $($_.Exception.Message)"
}

# ---------------------------------------------------------------- per-tool installers

Write-Host "`nAdding the MCP server ($McpUrl):"
if ($Clients.Count -eq 0) {
    Write-Warn 'No supported tools found. Any MCP client that supports Streamable HTTP and a custom'
    Write-Warn 'Authorization header can use the URL above with "Authorization: Bearer <key>".'
}

foreach ($id in @($Clients.Keys)) {
    switch ($id) {
        'claude-code' {
            Invoke-Step $id {
                if (-not $ClaudeBin) { throw "Claude Code config found but the 'claude' command is not on PATH" }
                # Native commands write to stderr on normal failures, which Stop would turn into an exception.
                $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                try {
                    & $ClaudeBin mcp remove connectionshub --scope user 2>&1 | Out-Null
                    $out = & $ClaudeBin mcp add --scope user --transport http connectionshub $McpUrl --header "Authorization: Bearer $Key" 2>&1
                    $code = $LASTEXITCODE
                } finally { $ErrorActionPreference = $prev }
                if ($code -ne 0) { throw "claude mcp add failed: $out" }
                try { Update-JsonConfig "$Home_\.claude\settings.json" 'claude-settings' }
                catch { Write-Warn "Could not raise MAX_MCP_OUTPUT_TOKENS in ~\.claude\settings.json: $($_.Exception.Message)" }
                Write-Ok "user-scope server 'connectionshub' (check with /mcp)"
            }
        }
        'claude-desktop' {
            Invoke-Step $id {
                Update-JsonConfig "$DesktopDir\claude_desktop_config.json" 'desktop'
                if (-not (Test-Cmd npx)) { Write-Warn 'Claude Desktop needs Node.js (npx) to reach the server. Install it from https://nodejs.org' }
                Write-Ok 'claude_desktop_config.json'
                $Notes.Add('Quit and reopen Claude Desktop.')
            }
        }
        'cursor' {
            Invoke-Step $id {
                # User-level file, outside any project, with the key inside so it works however Cursor is launched.
                Update-JsonConfig "$Home_\.cursor\mcp.json" 'cursor'
                Write-Ok '~\.cursor\mcp.json'
                $Notes.Add("In Cursor Settings, switch the 'connectionshub' MCP server on. Cursor adds it switched off.")
            }
        }
        'vscode' {
            Invoke-Step $id {
                Update-JsonConfig "$AppData\Code\User\mcp.json" 'vscode'
                Write-Ok 'user mcp.json (VS Code asks for the key the first time the server starts)'
                $Notes.Add('VS Code: use Copilot Chat in Agent mode and turn on the connectionshub tools under Configure Tools.')
            }
        }
        'windsurf' {
            Invoke-Step $id {
                Update-JsonConfig "$Home_\.codeium\windsurf\mcp_config.json" 'windsurf'
                Write-Ok '~\.codeium\windsurf\mcp_config.json'
                $Notes.Add('Windsurf: refresh the MCP list in Cascade, or restart Windsurf.')
            }
        }
        'antigravity' {
            Invoke-Step $id {
                # The IDE, CLI and 2.0 share ~\.gemini\config\mcp_config.json. Older IDE builds read
                # ~\.gemini\antigravity\mcp_config.json, so that file is updated too when its folder exists.
                Update-JsonConfig "$Home_\.gemini\config\mcp_config.json" 'antigravity'
                Write-Ok '~\.gemini\config\mcp_config.json'
                if (Test-Path "$Home_\.gemini\antigravity") {
                    Update-JsonConfig "$Home_\.gemini\antigravity\mcp_config.json" 'antigravity'
                    Write-Ok '~\.gemini\antigravity\mcp_config.json (older layout)'
                }
                $Notes.Add('Antigravity: open Manage MCP Servers and click Refresh, or restart it.')
            }
        }
        'codex' {
            Invoke-Step $id {
                $f = "$Home_\.codex\config.toml"
                $kept = New-Object System.Collections.Generic.List[string]
                if (Test-Path -LiteralPath $f) {
                    $skip = $false
                    foreach ($line in (Get-Content -LiteralPath $f)) {
                        if ($line -match '^\[') { $skip = ($line -match '^\[mcp_servers\.connectionshub(\]|\.)') }
                        if (-not $skip) { $kept.Add($line) }
                    }
                }
                while ($kept.Count -gt 0 -and [string]::IsNullOrWhiteSpace($kept[$kept.Count - 1])) { $kept.RemoveAt($kept.Count - 1) }
                if ($kept.Count -gt 0) { $kept.Add('') }
                $kept.Add('[mcp_servers.connectionshub]')
                $kept.Add("url = `"$McpUrl`"")
                $kept.Add("bearer_token_env_var = `"$EnvName`"")
                $kept.Add('tool_timeout_sec = 120')
                Backup-File $f
                Write-Text $f (($kept -join "`n") + "`n")
                Remove-BackupIfSame $f
                Write-Ok "~\.codex\config.toml (reads the key from $EnvName, 120 s tool timeout)"
                $Notes.Add("Codex reads $EnvName when it starts. Start it from a new terminal window.")
            }
        }
        'gemini' {
            Invoke-Step $id {
                Update-JsonConfig "$Home_\.gemini\settings.json" 'gemini'
                Write-Ok "~\.gemini\settings.json (reads the key from $EnvName)"
            }
        }
    }
}

# ---------------------------------------------------------------- summary

Write-Host ''
if ($Done.Count -gt 0) { Write-Host ('Configured: ' + ($Done -join ', ')) }
if ($Problems.Count -gt 0) {
    Write-Host ('Needs attention: ' + ($Problems -join ', ')) -ForegroundColor Yellow
    Write-Host 'See the messages above. Nothing was overwritten for those. Manual steps: https://connectionshub.atlastube.com/docs/api/mcp'
}
if ($Notes.Count -gt 0) {
    Write-Host 'Next steps:'
    foreach ($n in $Notes) { Write-Host "  - $n" }
}
Write-Host "`nTest it by asking your tool: `"List the Connections Hub calculators.`""
if ($Problems.Count -gt 0) { exit 1 }

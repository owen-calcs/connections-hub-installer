# Connections Hub installer

Sets up the HSS Connections Hub API key and MCP server for the AI tools on your machine.

Docs: https://connectionshub.atlastube.com/docs/api/mcp

## Mac

On Finder:

Double click the `install-connections-hub.sh` file:
<img width="913" height="239" alt="Screenshot 2026-10-25 at 4 54 15 pm" src="https://github.com/user-attachments/assets/91084817-34d9-4d2a-8353-3545ea5de50b" />

Then paste in your API key from your email. Note: paste is hidden, so it won't show you what you're pasting in for security reasons.

<img width="654" height="254" alt="Screenshot 2026-10-25 at 4 55 09 pm" src="https://github.com/user-attachments/assets/f014ebc7-c457-4272-9825-2899b543fb49" />

It will install an environment variable, `HUB_API_KEY` and install the MCP for all the installed applications it detects.

<img width="902" height="695" alt="Screenshot 2026-10-25 at 4 55 35 pm" src="https://github.com/user-attachments/assets/0ae04166-837d-4a13-9ecb-69c5e3866ab0" />


```bash
./install-connections-hub.sh YOUR_API_KEY
```

## Windows

Double-click `install-connections-hub.cmd`, paste the key when it asks (right-click pastes), and press Enter. The window stays open at the end so you can read the result.

Or from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-connections-hub.ps1 YOUR_API_KEY
```

Leave the key off and the script asks for it, showing `*` as you paste. `--detect` (`-Detect` on Windows) lists the tools it finds and changes nothing. `--skip-verify` (`-SkipVerify`) skips the key check.

## What it does

1. Checks the key against the API.
2. Saves the key as `HUB_API_KEY`. On Mac that is `~/.config/connectionshub/hub-api-key.sh`, sourced from your shell rc file. On Windows it is a user environment variable.
3. Adds a `connectionshub` MCP server (`https://api.calcs.com/mcp`) to each tool it finds:

| Tool | Config |
|---|---|
| Claude Code | `claude mcp add --scope user`, plus `MAX_MCP_OUTPUT_TOKENS` in `~/.claude/settings.json` |
| Claude Desktop | `claude_desktop_config.json`, via `mcp-remote` (needs Node.js) |
| Cursor | `~/.cursor/mcp.json` |
| VS Code | user `mcp.json`, prompts for the key |
| Windsurf | `~/.codeium/windsurf/mcp_config.json` |
| Antigravity | `~/.gemini/config/mcp_config.json` (and `~/.gemini/antigravity/mcp_config.json` if that folder exists) |
| Codex | `~/.codex/config.toml`, reads `HUB_API_KEY` |
| Gemini CLI | `~/.gemini/settings.json`, reads `HUB_API_KEY` |

Config files are backed up as `<file>.bak-<timestamp>` before they change. A file that is not plain JSON is left alone and reported. Running the script again replaces the existing entry.

## Status

The Mac script is tested against a fake home folder. The Windows script has not been run yet. The Windsurf and Antigravity formats come from those tools' own docs, not the Hub docs. Antigravity's config path has changed between releases, and I have not run it against a real install.

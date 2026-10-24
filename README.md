# Connections Hub installer

Sets up the HSS Connections Hub API key and MCP server for the AI tools on your machine.

Docs: https://connectionshub.atlastube.com/docs/api/mcp

## Mac

```bash
./install-connections-hub.sh YOUR_API_KEY
```

## Windows

```powershell
powershell -ExecutionPolicy Bypass -File .\install-connections-hub.ps1 YOUR_API_KEY
```

Leave the key off and the script asks for it with hidden input. `--detect` (`-Detect` on Windows) lists the tools it finds and changes nothing. `--skip-verify` (`-SkipVerify`) skips the key check.

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
| Codex | `~/.codex/config.toml`, reads `HUB_API_KEY` |
| Gemini CLI | `~/.gemini/settings.json`, reads `HUB_API_KEY` |

Config files are backed up as `<file>.bak-<timestamp>` before they change. A file that is not plain JSON is left alone and reported. Running the script again replaces the existing entry.

## Status

The Mac script is tested against a fake home folder. The Windows script has not been run yet. The Windsurf format comes from Windsurf's own docs, not the Hub docs.

#!/usr/bin/env bash
#
# Sets up the HSS Connections Hub API key and the Connections Hub MCP server on a Mac.
#
#   ./install-connections-hub.sh YOUR_API_KEY
#   ./install-connections-hub.sh --detect            list detected tools, change nothing
#   ./install-connections-hub.sh YOUR_API_KEY --skip-verify
#
# What it does:
#   1. Checks the key against the API (skip with --skip-verify).
#   2. Saves the key as HUB_API_KEY for the REST API (curl, scripts, Codex, Gemini CLI).
#   3. Adds the "connectionshub" MCP server to each tool it finds:
#        Claude Code, Claude Desktop, Cursor, VS Code, Windsurf, Codex, Gemini CLI
#
# Existing config files are backed up as <file>.bak-<timestamp> before they change.
# A file that is not plain JSON (for example VS Code settings with comments) is left alone
# and reported, so run it again after fixing the file or add the entry by hand.

set -u

MCP_URL="https://api.calcs.com/mcp"
API_URL="https://api.calcs.com/v1/projects"
ENV_NAME="HUB_API_KEY"
ENV_DIR="$HOME/.config/connectionshub"
ENV_FILE="$ENV_DIR/hub-api-key.sh"
MARK_BEGIN="# >>> connections hub >>>"
MARK_END="# <<< connections hub <<<"
STAMP="$(date +%Y%m%d-%H%M%S)"

KEY=""
DETECT_ONLY=0
SKIP_VERIFY=0

usage() {
  sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case "$arg" in
    --detect) DETECT_ONLY=1 ;;
    --skip-verify) SKIP_VERIFY=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
    *) KEY="$arg" ;;
  esac
done

if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_OFF=""
fi
ok()   { printf '  %s✓%s %s\n' "$C_OK" "$C_OFF" "$1"; }
warn() { printf '  %s!%s %s\n' "$C_WARN" "$C_OFF" "$1"; }
fail() { printf '  %s✗%s %s\n' "$C_ERR" "$C_OFF" "$1"; }
dim()  { printf '  %s%s%s\n' "$C_DIM" "$1" "$C_OFF"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }
have_app() { [ -d "/Applications/$1.app" ] || [ -d "$HOME/Applications/$1.app" ]; }

# ---------------------------------------------------------------- detection

CLAUDE_BIN=""
for p in "$(command -v claude 2>/dev/null)" "$HOME/.claude/local/claude" "$HOME/.local/bin/claude" "/opt/homebrew/bin/claude" "/usr/local/bin/claude"; do
  if [ -n "$p" ] && [ -x "$p" ]; then CLAUDE_BIN="$p"; break; fi
done

CLIENTS=""   # space separated ids of detected tools
detected() { case " $CLIENTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
add_client() { CLIENTS="$CLIENTS $1"; }

[ -n "$CLAUDE_BIN" ] || [ -d "$HOME/.claude" ] && add_client claude-code
{ have_app "Claude" || [ -d "$HOME/Library/Application Support/Claude" ]; } && add_client claude-desktop
{ have_app "Cursor" || have_cmd cursor || [ -d "$HOME/.cursor" ]; } && add_client cursor
{ have_app "Visual Studio Code" || have_cmd code || [ -d "$HOME/Library/Application Support/Code/User" ]; } && add_client vscode
{ have_app "Windsurf" || have_cmd windsurf || [ -d "$HOME/.codeium/windsurf" ]; } && add_client windsurf
{ have_app "Codex" || have_cmd codex || [ -d "$HOME/.codex" ]; } && add_client codex
{ have_cmd gemini || [ -d "$HOME/.gemini" ]; } && add_client gemini

label() {
  case "$1" in
    claude-code) echo "Claude Code" ;;
    claude-desktop) echo "Claude Desktop" ;;
    cursor) echo "Cursor" ;;
    vscode) echo "VS Code (GitHub Copilot)" ;;
    windsurf) echo "Windsurf" ;;
    codex) echo "Codex" ;;
    gemini) echo "Gemini CLI" ;;
  esac
}

echo "Detected tools:"
if [ -z "${CLIENTS// /}" ]; then
  dim "none found"
else
  for c in $CLIENTS; do ok "$(label "$c")"; done
fi

if [ "$DETECT_ONLY" = 1 ]; then exit 0; fi

# ---------------------------------------------------------------- the key

if [ "$(uname -s)" != "Darwin" ]; then
  fail "This script is for macOS. Use install-connections-hub.ps1 on Windows."
  exit 1
fi

if [ -z "$KEY" ]; then
  if [ -t 0 ] || [ -r /dev/tty ]; then
    printf 'Paste your Connections Hub API key (input is hidden): ' >/dev/tty
    IFS= read -rs KEY </dev/tty
    printf '\n' >/dev/tty
  fi
fi

# Accept a pasted "Bearer xxx", quotes, or stray whitespace.
KEY="${KEY#Bearer }"
KEY="$(printf '%s' "$KEY" | tr -d '[:space:]"'"'")"

if [ -z "$KEY" ]; then
  fail "No API key given. Usage: $0 YOUR_API_KEY"
  exit 1
fi

echo
echo "Checking the key:"
if [ "$SKIP_VERIFY" = 1 ]; then
  dim "skipped"
else
  code="$(curl -s -o /dev/null -m 15 -w '%{http_code}' -H "Authorization: Bearer $KEY" "$API_URL" 2>/dev/null || true)"
  case "$code" in
    200) ok "API accepted the key" ;;
    401|403) fail "API rejected the key (HTTP $code). Check you copied all of it."; exit 1 ;;
    000|"") warn "Could not reach api.calcs.com, carrying on without checking the key" ;;
    *) warn "API answered HTTP $code, carrying on" ;;
  esac
fi

# ---------------------------------------------------------------- helpers

DONE=""; PROBLEMS=""; NOTES=""
note() { NOTES="$NOTES
  - $1"; }
done_for() { DONE="$DONE $1"; }
problem_for() { PROBLEMS="$PROBLEMS $1"; }

# prints stdin without trailing blank lines
trim_blanks() { awk '{ a[NR] = $0 } END { n = NR; while (n > 0 && a[n] == "") n--; for (i = 1; i <= n; i++) print a[i] }'; }

backup() { [ -f "$1" ] && cp -p "$1" "$1.bak-$STAMP"; }

# Edits one JSON config. The key reaches osascript through the environment, never
# through the command line or string interpolation, so no quoting can mangle it.
JXA=$(cat <<'JXA_EOF'
ObjC.import('Foundation');
const env = $.NSProcessInfo.processInfo.environment;
const get = k => { const v = env.objectForKey(k); return v.isNil() ? '' : ObjC.unwrap(v); };
const file = get('HUB_FILE'), kind = get('HUB_KIND'), key = get('HUB_KEY'), url = get('HUB_URL');

let obj = {};
if ($.NSFileManager.defaultManager.fileExistsAtPath(file)) {
  const s = $.NSString.stringWithContentsOfFileEncodingError(file, $.NSUTF8StringEncoding, $());
  const text = s.isNil() ? '' : ObjC.unwrap(s);
  if (text.trim() !== '') {
    try { obj = JSON.parse(text); } catch (e) { throw new Error('file is not plain JSON (comments or a syntax error)'); }
  }
}
if (obj === null || typeof obj !== 'object' || Array.isArray(obj)) throw new Error('file is not a JSON object');

const bearer = 'Bearer ' + key;
const putServer = (top, entry) => {
  if (obj[top] === null || typeof obj[top] !== 'object' || Array.isArray(obj[top])) obj[top] = {};
  obj[top].connectionshub = entry;
};

switch (kind) {
  case 'cursor':
    putServer('mcpServers', { url: url, headers: { Authorization: bearer } });
    break;
  case 'windsurf':
    putServer('mcpServers', { serverUrl: url, headers: { Authorization: bearer } });
    break;
  case 'desktop':
    putServer('mcpServers', {
      command: 'npx',
      args: ['-y', 'mcp-remote', url, '--header', 'Authorization:${HUB_AUTH}'],
      env: { HUB_AUTH: bearer }
    });
    break;
  case 'gemini':
    putServer('mcpServers', { httpUrl: url, headers: { Authorization: 'Bearer $HUB_API_KEY' } });
    break;
  case 'vscode': {
    const input = { type: 'promptString', id: 'connectionshub-api-key', description: 'Connections Hub API key', password: true };
    const rest = Array.isArray(obj.inputs) ? obj.inputs.filter(i => !i || i.id !== input.id) : [];
    obj.inputs = rest.concat([input]);
    putServer('servers', { type: 'http', url: url, headers: { Authorization: 'Bearer ${input:connectionshub-api-key}' } });
    break;
  }
  case 'claude-settings': {
    if (obj.env === null || typeof obj.env !== 'object' || Array.isArray(obj.env)) obj.env = {};
    const cur = parseInt(obj.env.MAX_MCP_OUTPUT_TOKENS, 10);
    if (!(cur >= 100000)) obj.env.MAX_MCP_OUTPUT_TOKENS = '100000';
    break;
  }
  default:
    throw new Error('unknown kind ' + kind);
}

const out = $(JSON.stringify(obj, null, 2) + '\n');
if (!out.writeToFileAtomicallyEncodingError(file, true, $.NSUTF8StringEncoding, $())) throw new Error('write failed');
JXA_EOF
)

# json_upsert <file> <kind> [secret]   "secret" means the file now holds the key
json_upsert() {
  local file="$1" kind="$2" secret="${3:-}" err
  mkdir -p "$(dirname "$file")" || return 1
  backup "$file"
  if ! err="$(HUB_FILE="$file" HUB_KIND="$kind" HUB_KEY="$KEY" HUB_URL="$MCP_URL" \
        osascript -l JavaScript -e "$JXA" 2>&1)"; then
    rm -f "$file.bak-$STAMP"
    err="$(printf '%s' "$err" | sed -E 's/^.*(Error: )+//; s/ \(-[0-9]+\)$//')"
    fail "$file: $err"
    return 1
  fi
  [ "$secret" = secret ] && chmod 600 "$file"
  # Drop the backup when nothing changed, so repeat runs do not pile them up.
  if [ -f "$file.bak-$STAMP" ] && cmp -s "$file" "$file.bak-$STAMP"; then rm -f "$file.bak-$STAMP"; fi
  return 0
}

# ---------------------------------------------------------------- the API key (HUB_API_KEY)

install_env() {
  mkdir -p "$ENV_DIR" || return 1
  local esc
  esc="$(printf '%s' "$KEY" | sed "s/'/'\\\\''/g")"
  ( umask 077; printf "export %s='%s'\n" "$ENV_NAME" "$esc" > "$ENV_FILE" ) || return 1
  chmod 600 "$ENV_FILE"

  local line="[ -f \"$ENV_FILE\" ] && . \"$ENV_FILE\""
  local shellname rc targets=""
  shellname="$(basename "${SHELL:-/bin/zsh}")"
  case "$shellname" in
    zsh)  targets="$HOME/.zshrc" ;;
    bash) targets="$HOME/.bash_profile" ;;
    fish) note "Your shell is fish. Run: set -Ux $ENV_NAME YOUR_API_KEY" ;;
    *)    targets="$HOME/.profile" ;;
  esac
  for rc in "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc"; do
    [ -f "$rc" ] && case " $targets " in *" $rc "*) ;; *) targets="$targets $rc" ;; esac
  done

  for rc in $targets; do
    local tmp
    tmp="$(mktemp)"
    if [ -f "$rc" ]; then
      awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip   { print }' "$rc" | trim_blanks > "$tmp"
    fi
    { cat "$tmp"; [ -s "$tmp" ] && printf '\n'; printf '%s\n%s\n%s\n' "$MARK_BEGIN" "$line" "$MARK_END"; } > "$tmp.new"
    if [ -f "$rc" ]; then cat "$tmp.new" > "$rc"; else sed '1{/^$/d;}' "$tmp.new" > "$rc"; fi
    rm -f "$tmp" "$tmp.new"
    dim "sourced from $rc"
  done
  return 0
}

echo
echo "Saving the API key as $ENV_NAME:"
if install_env; then
  ok "$ENV_FILE (chmod 600)"
  note "Open a new terminal window so $ENV_NAME is set there."
else
  fail "Could not write $ENV_FILE"
fi

# ---------------------------------------------------------------- per-tool installers

install_claude_code() {
  if [ -z "$CLAUDE_BIN" ]; then
    warn "Claude Code config found but the 'claude' command is not on PATH"
    return 1
  fi
  "$CLAUDE_BIN" mcp remove connectionshub --scope user >/dev/null 2>&1
  local err
  if ! err="$("$CLAUDE_BIN" mcp add --scope user --transport http connectionshub "$MCP_URL" \
        --header "Authorization: Bearer $KEY" 2>&1)"; then
    fail "claude mcp add failed: $err"
    return 1
  fi
  # get_calculator replies are big, Claude Code's default output limit is too low for them
  json_upsert "$HOME/.claude/settings.json" claude-settings || warn "Could not raise MAX_MCP_OUTPUT_TOKENS in ~/.claude/settings.json"
  ok "user-scope server 'connectionshub' (check with /mcp)"
}

install_claude_desktop() {
  json_upsert "$HOME/Library/Application Support/Claude/claude_desktop_config.json" desktop secret || return 1
  have_cmd npx || warn "Claude Desktop needs Node.js (npx) to reach the server. Install it from https://nodejs.org"
  ok "claude_desktop_config.json"
  note "Quit and reopen Claude Desktop."
}

install_cursor() {
  # Written with the key inside, because Cursor opened from the Dock cannot see shell variables.
  # This is Cursor's user-level file, outside any project.
  json_upsert "$HOME/.cursor/mcp.json" cursor secret || return 1
  ok "~/.cursor/mcp.json"
  note "In Cursor Settings, switch the 'connectionshub' MCP server on. Cursor adds it switched off."
}

install_vscode() {
  json_upsert "$HOME/Library/Application Support/Code/User/mcp.json" vscode || return 1
  ok "user mcp.json (VS Code asks for the key the first time the server starts)"
  note "VS Code: use Copilot Chat in Agent mode and turn on the connectionshub tools under Configure Tools."
}

install_windsurf() {
  json_upsert "$HOME/.codeium/windsurf/mcp_config.json" windsurf secret || return 1
  ok "~/.codeium/windsurf/mcp_config.json"
  note "Windsurf: refresh the MCP list in Cascade, or restart Windsurf."
}

install_codex() {
  local f="$HOME/.codex/config.toml" tmp
  mkdir -p "$HOME/.codex" || return 1
  backup "$f"
  tmp="$(mktemp)"
  if [ -f "$f" ]; then
    awk '
      /^\[/ { skip = ($0 ~ /^\[mcp_servers\.connectionshub(\]|\.)/) }
      !skip { print }' "$f" | trim_blanks > "$tmp"
  fi
  {
    cat "$tmp"
    [ -s "$tmp" ] && printf '\n'
    cat <<TOML
[mcp_servers.connectionshub]
url = "$MCP_URL"
bearer_token_env_var = "$ENV_NAME"
tool_timeout_sec = 120
TOML
  } > "$tmp.new"
  cat "$tmp.new" > "$f"
  rm -f "$tmp" "$tmp.new"
  if [ -f "$f.bak-$STAMP" ] && cmp -s "$f" "$f.bak-$STAMP"; then rm -f "$f.bak-$STAMP"; fi
  ok "~/.codex/config.toml (reads the key from $ENV_NAME, 120 s tool timeout)"
  note "Codex reads $ENV_NAME from the terminal it starts in. Start it from a new terminal window."
}

install_gemini() {
  json_upsert "$HOME/.gemini/settings.json" gemini || return 1
  ok "~/.gemini/settings.json (reads the key from $ENV_NAME)"
}

echo
echo "Adding the MCP server ($MCP_URL):"
if [ -z "${CLIENTS// /}" ]; then
  warn "No supported tools found. Any MCP client that supports Streamable HTTP and a custom"
  warn "Authorization header can use the URL above with 'Authorization: Bearer <key>'."
fi
for c in $CLIENTS; do
  printf '%s\n' "$(label "$c")"
  fn="install_$(echo "$c" | tr '-' '_')"
  if "$fn"; then done_for "$c"; else problem_for "$c"; fi
done

# ---------------------------------------------------------------- summary

echo
if [ -n "$DONE" ]; then
  printf 'Configured:'; for c in $DONE; do printf ' %s,' "$(label "$c")"; done | sed 's/,$//'; echo
fi
if [ -n "$PROBLEMS" ]; then
  printf '%sNeeds attention:%s' "$C_WARN" "$C_OFF"; for c in $PROBLEMS; do printf ' %s,' "$(label "$c")"; done | sed 's/,$//'; echo
  echo "See the messages above. Nothing was overwritten for those. Manual steps: https://connectionshub.atlastube.com/docs/api/mcp"
fi
if [ -n "$NOTES" ]; then
  echo "Next steps:$NOTES"
fi
echo
echo "Test it by asking your tool: \"List the Connections Hub calculators.\""

[ -z "$PROBLEMS" ]

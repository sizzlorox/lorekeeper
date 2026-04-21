#!/usr/bin/env bash
# lorekeeper uninstaller
# Removes hooks, CLAUDE.md block, qmd collections. Leaves notes/docs untouched.

set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
BIN_DIR="${LOREKEEPER_BIN:-$HOME/.local/bin}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!!\033[0m %s\n" "$*" >&2; }
die()  { printf "\033[1;31mxx\033[0m %s\n" "$*" >&2; exit 1; }

# --- OS detect: Windows must use uninstall.ps1 ---
case "${OSTYPE:-}" in
  msys*|cygwin*|win32)
    warn "Windows environment detected ($OSTYPE). Use uninstall.ps1:"
    warn "  powershell -ExecutionPolicy Bypass -File \"$SCRIPT_DIR/uninstall.ps1\""
    die  "aborting — uninstall.sh is for Linux/macOS only."
    ;;
esac
if command -v uname >/dev/null 2>&1; then
  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*)
      warn "Windows environment detected ($(uname -s)). Use uninstall.ps1:"
      warn "  powershell -ExecutionPolicy Bypass -File \"$SCRIPT_DIR/uninstall.ps1\""
      die  "aborting — uninstall.sh is for Linux/macOS only."
      ;;
  esac
fi

# --- remove hook files ---
say "removing hook scripts"
rm -f "$CLAUDE_DIR/hooks/lorekeeper-prime.sh" "$CLAUDE_DIR/hooks/lorekeeper-reindex.sh"

# --- scrub settings.json ---
SETTINGS="$CLAUDE_DIR/settings.json"
if [[ -f "$SETTINGS" ]]; then
  say "scrubbing hook entries from $SETTINGS"
  TMP="$(mktemp)"
  jq '
    def scrub:
      map(
        .hooks |= (map(select((.command | tostring) | test("lorekeeper-(prime|reindex)\\.sh") | not)))
      )
      | map(select((.hooks // []) | length > 0));
    if .hooks then
      .hooks.SessionStart      = ((.hooks.SessionStart      // []) | scrub) |
      .hooks.UserPromptSubmit  = ((.hooks.UserPromptSubmit  // []) | scrub) |
      .hooks.PostToolUse       = ((.hooks.PostToolUse       // []) | scrub)
    else . end
  ' "$SETTINGS" > "$TMP"
  mv "$TMP" "$SETTINGS"
fi

# --- remove CLAUDE.md block ---
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
if [[ -f "$CLAUDE_MD" ]] && grep -qF "<!-- LOREKEEPER:START -->" "$CLAUDE_MD"; then
  say "removing policy block from $CLAUDE_MD"
  awk '
    BEGIN { skip = 0 }
    /<!-- LOREKEEPER:START -->/ { skip = 1; next }
    /<!-- LOREKEEPER:END -->/   { skip = 0; next }
    !skip
  ' "$CLAUDE_MD" > "$CLAUDE_MD.tmp"
  mv "$CLAUDE_MD.tmp" "$CLAUDE_MD"
fi

# --- qmd collections ---
say "removing qmd collections (notes + docs)"
qmd collection remove lorekeeper-notes 2>/dev/null || true
qmd collection remove lorekeeper-docs  2>/dev/null || true

# --- CLI + state ---
# Capture the recorded home before we delete its breadcrumb, so the farewell
# message can point at the actual directory. Also sidesteps SC2016 by using
# an escaped literal '\$LOREKEEPER_HOME' in the fallback text.
home_file="$CLAUDE_DIR/.lorekeeper-home"
saved_home=""
[[ -f "$home_file" ]] && saved_home="$(cat "$home_file" 2>/dev/null)"

rm -f "$BIN_DIR/lorekeeper"
rm -f "$home_file"

cat <<EOF

uninstalled. your notes and docs are still at:
  ${saved_home:-(see \$LOREKEEPER_HOME or ~/.local/share/lorekeeper)}

delete them by hand if you want them gone.
EOF

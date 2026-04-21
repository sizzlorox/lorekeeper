#!/usr/bin/env bash
# lorekeeper installer — idempotent
# Wires qmd collections, Claude Code hooks, and CLAUDE.md policy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
LOREKEEPER_HOME_DEFAULT="$XDG_DATA_HOME/lorekeeper"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# --- args ---
LOREKEEPER_HOME="$LOREKEEPER_HOME_DEFAULT"
WITH_CAVEMAN=false
NO_CAVEMAN=false
NO_EMBED_BOOTSTRAP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lorekeeper-home)   LOREKEEPER_HOME="$2"; shift 2 ;;
    --with-caveman)      WITH_CAVEMAN=true; shift ;;
    --no-caveman)        NO_CAVEMAN=true; shift ;;
    --no-embed-bootstrap) NO_EMBED_BOOTSTRAP=true; shift ;;
    -h|--help)
      sed -n '2,15p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

say()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!!\033[0m %s\n" "$*" >&2; }
die()  { printf "\033[1;31mxx\033[0m %s\n" "$*" >&2; exit 1; }

# --- OS detect: Windows (Git Bash / MSYS / Cygwin) must use install.ps1 ---
case "${OSTYPE:-}" in
  msys*|cygwin*|win32)
    warn "Windows environment detected ($OSTYPE)."
    warn "Use the native PowerShell installer instead:"
    warn "  powershell -ExecutionPolicy Bypass -File \"$SCRIPT_DIR/install.ps1\""
    die  "aborting — install.sh is for Linux/macOS only."
    ;;
esac
# Also catch when $OSTYPE is unset but uname reports MINGW/MSYS
if command -v uname >/dev/null 2>&1; then
  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*)
      warn "Windows environment detected ($(uname -s))."
      warn "Use the native PowerShell installer instead:"
      warn "  powershell -ExecutionPolicy Bypass -File \"$SCRIPT_DIR/install.ps1\""
      die  "aborting — install.sh is for Linux/macOS only."
      ;;
  esac
fi

# --- preflight ---
command -v jq   >/dev/null || die "jq not found. install with: brew install jq  |  apt install jq"
command -v git  >/dev/null || die "git not found."
command -v node >/dev/null || die "node not found (≥22 required for qmd)."

if ! command -v qmd >/dev/null; then
  say "qmd not found — installing @tobilu/qmd globally via npm"
  npm install -g @tobilu/qmd || die "qmd install failed. try: npm install -g @tobilu/qmd"
fi

if ! command -v claude >/dev/null; then
  warn "claude CLI not on PATH. Install Claude Code first: https://code.claude.com"
fi

# --- caveman detection ---
CAVEMAN_ACTIVE=false
if $WITH_CAVEMAN && $NO_CAVEMAN; then
  die "--with-caveman and --no-caveman are mutually exclusive"
fi

if $WITH_CAVEMAN; then
  if command -v claude >/dev/null; then
    say "installing caveman plugin"
    claude plugin marketplace add JuliusBrussee/caveman 2>/dev/null || true
    claude plugin install caveman@caveman 2>/dev/null || warn "caveman install returned non-zero; check with 'claude plugin list'"
  fi
  CAVEMAN_ACTIVE=true
elif $NO_CAVEMAN; then
  CAVEMAN_ACTIVE=false
else
  # auto-detect
  if command -v claude >/dev/null && claude plugin list 2>/dev/null | grep -qi "caveman"; then
    say "caveman plugin detected — using compressed CLAUDE.md"
    CAVEMAN_ACTIVE=true
  fi
fi

# --- directories ---
say "creating lorekeeper home: $LOREKEEPER_HOME"
mkdir -p "$LOREKEEPER_HOME/notes" "$LOREKEEPER_HOME/docs"
mkdir -p "$CLAUDE_DIR/hooks"

# Record home so CLI and hooks share it
echo "$LOREKEEPER_HOME" > "$CLAUDE_DIR/.lorekeeper-home"

# --- copy hooks ---
say "installing hooks to $CLAUDE_DIR/hooks"
install -m 0755 "$SCRIPT_DIR/hooks/prime.sh"   "$CLAUDE_DIR/hooks/lorekeeper-prime.sh"
install -m 0755 "$SCRIPT_DIR/hooks/reindex.sh" "$CLAUDE_DIR/hooks/lorekeeper-reindex.sh"

# --- install bin ---
BIN_DIR="${LOREKEEPER_BIN:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"
install -m 0755 "$SCRIPT_DIR/bin/lorekeeper" "$BIN_DIR/lorekeeper"
say "installed CLI: $BIN_DIR/lorekeeper"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on PATH. add to your shell rc: export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

# --- merge hooks into settings.json ---
SETTINGS="$CLAUDE_DIR/settings.json"
say "merging hook config into $SETTINGS"

[[ -f "$SETTINGS" ]] || echo "{}" > "$SETTINGS"

# Build the hooks fragment — single jq expression keeps things atomic
TMP="$(mktemp)"
jq --arg prime   "bash $CLAUDE_DIR/hooks/lorekeeper-prime.sh" \
   --arg reindex "bash $CLAUDE_DIR/hooks/lorekeeper-reindex.sh" '
   .hooks = (.hooks // {}) |
   .hooks.SessionStart = (
     (.hooks.SessionStart // [])
     | map(select(
         (.hooks // []) | map(.command) | any(. == $prime) | not
       ))
     | . + [ { "hooks": [ { "type": "command", "command": $prime } ] } ]
   ) |
   .hooks.UserPromptSubmit = (
     (.hooks.UserPromptSubmit // [])
     | map(select(
         (.hooks // []) | map(.command) | any(. == $prime) | not
       ))
     | . + [ { "hooks": [ { "type": "command", "command": $prime } ] } ]
   ) |
   .hooks.PostToolUse = (
     (.hooks.PostToolUse // [])
     | map(select(
         (.hooks // []) | map(.command) | any(. == $reindex) | not
       ))
     | . + [ { "matcher": "Write|Edit", "hooks": [ { "type": "command", "command": $reindex } ] } ]
   )
' "$SETTINGS" > "$TMP"
mv "$TMP" "$SETTINGS"

# --- CLAUDE.md injection ---
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
TEMPLATE_KEY="CLAUDE.md"
$CAVEMAN_ACTIVE && TEMPLATE_KEY="CLAUDE.caveman.md"
TEMPLATE="$SCRIPT_DIR/templates/$TEMPLATE_KEY"

say "injecting policy block into $CLAUDE_MD (source: $TEMPLATE_KEY)"
touch "$CLAUDE_MD"

START="<!-- LOREKEEPER:START -->"
END="<!-- LOREKEEPER:END -->"

# Materialize the substituted block to a temp file — avoids awk -v escape hazards
BLOCK_FILE="$(mktemp)"
sed "s|__LOREKEEPER_HOME__|$LOREKEEPER_HOME|g" "$TEMPLATE" > "$BLOCK_FILE"

if grep -qF "$START" "$CLAUDE_MD"; then
  # Replace existing block in-place
  awk -v start="$START" -v end="$END" -v block_file="$BLOCK_FILE" '
    BEGIN {
      in_block = 0
      while ((getline line < block_file) > 0) block_lines[block_count++] = line
      close(block_file)
    }
    $0 == start {
      print start
      for (i = 0; i < block_count; i++) print block_lines[i]
      print end
      in_block = 1
      next
    }
    $0 == end { in_block = 0; next }
    !in_block { print }
  ' "$CLAUDE_MD" > "$CLAUDE_MD.tmp"
  mv "$CLAUDE_MD.tmp" "$CLAUDE_MD"
else
  {
    [[ -s "$CLAUDE_MD" ]] && echo
    echo "$START"
    cat "$BLOCK_FILE"
    echo "$END"
  } >> "$CLAUDE_MD"
fi
rm -f "$BLOCK_FILE"

# --- qmd collections ---
bash "$SCRIPT_DIR/qmd/bootstrap.sh" "$LOREKEEPER_HOME"

if ! $NO_EMBED_BOOTSTRAP; then
  say "generating initial embeddings (this takes a moment on first run)"
  qmd embed || warn "qmd embed failed — run 'lorekeeper reindex' later"
fi

# --- done ---
cat <<EOF

$(tput bold 2>/dev/null)installed.$(tput sgr0 2>/dev/null)

  home:      $LOREKEEPER_HOME
  hooks:     $CLAUDE_DIR/hooks/{lorekeeper-prime,lorekeeper-reindex}.sh
  policy:    $CLAUDE_MD ($TEMPLATE_KEY)
  caveman:   $($CAVEMAN_ACTIVE && echo 'active' || echo 'off')

next:
  1. open a Claude Code session in a git repo
  2. run 'lorekeeper status' to verify wiring
  3. seed a repo: 'lorekeeper note <repo> architecture'
EOF

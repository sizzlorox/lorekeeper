#!/usr/bin/env bash
# lorekeeper installer — idempotent
# Wires qmd collections, Claude Code hooks, and CLAUDE.md policy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
LOREKEEPER_HOME_DEFAULT="$XDG_DATA_HOME/lorekeeper"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
OMP_DIR="${OMP_CONFIG_DIR:-$HOME/.omp}"

# --- args ---
LOREKEEPER_HOME="$LOREKEEPER_HOME_DEFAULT"
WITH_CAVEMAN=false
NO_CAVEMAN=false
NO_EMBED_BOOTSTRAP=false
NO_OMP=false
NO_CLAUDE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lorekeeper-home)   LOREKEEPER_HOME="$2"; shift 2 ;;
    --with-caveman)      WITH_CAVEMAN=true; shift ;;
    --no-caveman)        NO_CAVEMAN=true; shift ;;
    --no-embed-bootstrap) NO_EMBED_BOOTSTRAP=true; shift ;;
    --no-omp)            NO_OMP=true; shift ;;
    --no-claude)         NO_CLAUDE=true; shift ;;
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
mkdir -p "$LOREKEEPER_HOME/notes" "$LOREKEEPER_HOME/docs" "$LOREKEEPER_HOME/hooks"

# --- canonical hooks (consumed by both the Claude shim copies and the omp plugin) ---
say "installing canonical hooks to $LOREKEEPER_HOME/hooks"
install -m 0755 "$SCRIPT_DIR/hooks/prime.sh"    "$LOREKEEPER_HOME/hooks/prime.sh"
install -m 0755 "$SCRIPT_DIR/hooks/reindex.sh"  "$LOREKEEPER_HOME/hooks/reindex.sh"
install -m 0755 "$SCRIPT_DIR/hooks/autonote.sh" "$LOREKEEPER_HOME/hooks/autonote.sh"
# ps1 siblings ship alongside so a single $LOREKEEPER_HOME serves both
# bash and PowerShell installs without re-running the platform installer.
install -m 0644 "$SCRIPT_DIR/hooks/prime.ps1"    "$LOREKEEPER_HOME/hooks/prime.ps1"    2>/dev/null || true
install -m 0644 "$SCRIPT_DIR/hooks/reindex.ps1"  "$LOREKEEPER_HOME/hooks/reindex.ps1"  2>/dev/null || true
install -m 0644 "$SCRIPT_DIR/hooks/autonote.ps1" "$LOREKEEPER_HOME/hooks/autonote.ps1" 2>/dev/null || true

# --- Claude Code wiring ---
if ! $NO_CLAUDE; then
  mkdir -p "$CLAUDE_DIR/hooks"
  echo "$LOREKEEPER_HOME" > "$CLAUDE_DIR/.lorekeeper-home"
  say "installing Claude-Code hook shims to $CLAUDE_DIR/hooks"
  install -m 0755 "$LOREKEEPER_HOME/hooks/prime.sh"    "$CLAUDE_DIR/hooks/lorekeeper-prime.sh"
  install -m 0755 "$LOREKEEPER_HOME/hooks/reindex.sh"  "$CLAUDE_DIR/hooks/lorekeeper-reindex.sh"
  install -m 0755 "$LOREKEEPER_HOME/hooks/autonote.sh" "$CLAUDE_DIR/hooks/lorekeeper-autonote.sh"
fi

# --- install bin ---
BIN_DIR="${LOREKEEPER_BIN:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"
install -m 0755 "$SCRIPT_DIR/bin/lorekeeper" "$BIN_DIR/lorekeeper"
say "installed CLI: $BIN_DIR/lorekeeper"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on PATH. add to your shell rc: export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

# --- shared policy-block helper (used by both Claude CLAUDE.md and omp AGENTS.md) ---
inject_policy_block() {
  # $1=target md file, $2=template path (already exists)
  local target="$1" template="$2"
  local start="<!-- LOREKEEPER:START -->" end="<!-- LOREKEEPER:END -->"
  touch "$target"
  local block_file; block_file="$(mktemp)"
  sed "s|__LOREKEEPER_HOME__|$LOREKEEPER_HOME|g" "$template" > "$block_file"
  if grep -qF "$start" "$target"; then
    awk -v start="$start" -v end="$end" -v block_file="$block_file" '
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
    ' "$target" > "$target.tmp"
    mv "$target.tmp" "$target"
  else
    local sep_needed=0
    [[ -s "$target" ]] && sep_needed=1
    {
      [[ $sep_needed -eq 1 ]] && echo
      echo "$start"
      cat "$block_file"
      echo "$end"
    } >> "$target"
  fi
  rm -f "$block_file"
}

TEMPLATE_KEY="CLAUDE.md"
$CAVEMAN_ACTIVE && TEMPLATE_KEY="CLAUDE.caveman.md"
TEMPLATE="$SCRIPT_DIR/templates/$TEMPLATE_KEY"

# --- Claude Code wiring: settings.json hooks + CLAUDE.md injection ---
CLAUDE_MD=""
if ! $NO_CLAUDE; then
  SETTINGS="$CLAUDE_DIR/settings.json"
  say "merging hook config into $SETTINGS"
  [[ -f "$SETTINGS" ]] || echo "{}" > "$SETTINGS"

  TMP="$(mktemp)"
  jq --arg prime    "bash $CLAUDE_DIR/hooks/lorekeeper-prime.sh" \
     --arg reindex  "bash $CLAUDE_DIR/hooks/lorekeeper-reindex.sh" \
     --arg autonote "bash $CLAUDE_DIR/hooks/lorekeeper-autonote.sh" '
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
     ) |
     .hooks.SessionEnd = (
       (.hooks.SessionEnd // [])
       | map(select(
           (.hooks // []) | map(.command) | any(. == $autonote) | not
         ))
       | . + [ { "hooks": [ { "type": "command", "command": $autonote } ] } ]
     )
  ' "$SETTINGS" > "$TMP"
  mv "$TMP" "$SETTINGS"

  CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
  say "injecting policy block into $CLAUDE_MD (source: $TEMPLATE_KEY)"
  inject_policy_block "$CLAUDE_MD" "$TEMPLATE"
fi

# --- omp plugin install ---
OMP_INSTALLED=false
OMP_PLUGIN_PATH="$SCRIPT_DIR/omp-plugin"
AGENTS_MD=""
if ! $NO_OMP && [[ -d "$OMP_PLUGIN_PATH" ]]; then
  if ! command -v omp >/dev/null 2>&1; then
    say "omp CLI not on PATH — skipping omp plugin install (rerun after installing omp)"
  elif ! command -v bun >/dev/null 2>&1; then
    warn "omp detected but bun CLI is missing — install bun (https://bun.sh) then re-run this installer"
  else
    say "building omp plugin"
    ( cd "$OMP_PLUGIN_PATH" && bun install && bun run build ) || die "omp plugin build failed in $OMP_PLUGIN_PATH"

    # marker file: the plugin and the canonical hooks find $LOREKEEPER_HOME
    # via this file when CLAUDE_CONFIG_DIR is not present.
    mkdir -p "$OMP_DIR"
    echo "$LOREKEEPER_HOME" > "$OMP_DIR/.lorekeeper-home"

    # register the plugin under ~/.omp/plugins/ via symlink (no npm publish required)
    PLUGINS_DIR="$OMP_DIR/plugins"
    SCOPE_DIR="$PLUGINS_DIR/node_modules/@lorekeeper"
    LINK_PATH="$SCOPE_DIR/omp-plugin"
    mkdir -p "$SCOPE_DIR"
    [[ -L "$LINK_PATH" || -e "$LINK_PATH" ]] && rm -rf "$LINK_PATH"
    ln -s "$OMP_PLUGIN_PATH" "$LINK_PATH"
    say "linked omp plugin: $LINK_PATH -> $OMP_PLUGIN_PATH"

    PLUGINS_PKG="$PLUGINS_DIR/package.json"
    [[ -f "$PLUGINS_PKG" ]] || echo '{"name":"omp-plugins","private":true,"dependencies":{}}' > "$PLUGINS_PKG"
    TMP="$(mktemp)"
    jq '.dependencies = (.dependencies // {}) |
        .dependencies["@lorekeeper/omp-plugin"] = "link:./node_modules/@lorekeeper/omp-plugin"' \
       "$PLUGINS_PKG" > "$TMP"
    mv "$TMP" "$PLUGINS_PKG"

    AGENTS_MD="$OMP_DIR/AGENTS.md"
    say "injecting policy block into $AGENTS_MD (source: $TEMPLATE_KEY)"
    inject_policy_block "$AGENTS_MD" "$TEMPLATE"

    OMP_INSTALLED=true
  fi
fi

# --- qmd collections ---
bash "$SCRIPT_DIR/qmd/bootstrap.sh" "$LOREKEEPER_HOME"

if ! $NO_EMBED_BOOTSTRAP; then
  say "generating initial embeddings (this takes a moment on first run)"
  qmd embed || warn "qmd embed failed — run 'lorekeeper reindex' later"
fi

# --- done ---
claude_line="skipped (--no-claude)"
if ! $NO_CLAUDE; then
  claude_line="$CLAUDE_DIR/hooks/{lorekeeper-prime,lorekeeper-reindex,lorekeeper-autonote}.sh"
fi
policy_line=""
$NO_CLAUDE || policy_line="$CLAUDE_MD ($TEMPLATE_KEY)"
omp_line="not installed (CLI missing or skipped)"
$NO_OMP && omp_line="skipped (--no-omp)"
$OMP_INSTALLED && omp_line="$OMP_DIR/plugins/node_modules/@lorekeeper/omp-plugin -> $OMP_PLUGIN_PATH"
agents_line=""
$OMP_INSTALLED && agents_line="$AGENTS_MD ($TEMPLATE_KEY)"

cat <<EOF

$(tput bold 2>/dev/null)installed.$(tput sgr0 2>/dev/null)

  home:      $LOREKEEPER_HOME
  hooks:     $LOREKEEPER_HOME/hooks/{prime,reindex,autonote}.sh  (canonical)
  claude:    $claude_line
  policy:    ${policy_line:-—}
  omp:       $omp_line
  agents:    ${agents_line:-—}
  caveman:   $($CAVEMAN_ACTIVE && echo 'active' || echo 'off')

next:
  1. open a Claude Code or omp session in a git repo
  2. run 'lorekeeper status' to verify wiring
  3. seed a repo: 'lorekeeper note <repo> architecture'
EOF

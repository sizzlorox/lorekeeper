#!/usr/bin/env bash
# lorekeeper: SessionStart / UserPromptSubmit hook
# Reads cwd from Claude Code's JSON input, resolves the repo name, and emits
# an index of existing notes/docs. stdout becomes additional context.
#
# Safe to run on both hook events — a session-id marker guards against the
# UserPromptSubmit version re-injecting on every message.

set -e

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LOREKEEPER_HOME="$(cat "$CLAUDE_DIR/.lorekeeper-home" 2>/dev/null || echo "$HOME/.local/share/lorekeeper")"

input="$(cat)"
cwd="$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)"
session_id="$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)"
event="$(jq -r '.hook_event_name // empty' <<<"$input" 2>/dev/null)"

# Guard: on UserPromptSubmit, only fire once per session
if [[ "$event" == "UserPromptSubmit" && -n "$session_id" ]]; then
  marker_dir="${XDG_RUNTIME_DIR:-/tmp}/lorekeeper"
  mkdir -p "$marker_dir"
  marker="$marker_dir/session-$session_id"
  if [[ -e "$marker" ]]; then
    exit 0
  fi
  touch "$marker"
  # Keep the marker dir tidy — drop entries older than 1 day
  find "$marker_dir" -type f -mtime +1 -delete 2>/dev/null || true
fi

# Resolve repo name from git toplevel if possible
repo=""
if [[ -n "$cwd" && -d "$cwd" ]]; then
  toplevel="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$toplevel" ]] && repo="$(basename "$toplevel")"
  [[ -z "$repo" ]] && repo="$(basename "$cwd")"
fi

if [[ -z "$repo" ]]; then
  exit 0  # no cwd — nothing to prime
fi

notes_dir="$LOREKEEPER_HOME/notes/$repo"
docs_dir="$LOREKEEPER_HOME/docs/$repo"

# List helpers — only the path relative to $d, one per line.
# Portable: uses find + sed (no GNU -printf).
list_md() {
  local d="$1"
  [[ -d "$d" ]] || return 0
  find "$d" -maxdepth 3 -type f -name '*.md' 2>/dev/null \
    | sed "s|^$d/||" \
    | sort
}

notes_files="$(list_md "$notes_dir")"
docs_files="$(list_md "$docs_dir")"

if [[ -z "$notes_files" && -z "$docs_files" ]]; then
  # No memory yet — stay silent. The SessionEnd autonote hook captures
  # learnings without prompting Claude mid-session.
  exit 0
fi

cat <<EOF
## lorekeeper: repo '$repo'

Prior memory exists. Use \`mcp__qmd__query\` with collections=["lorekeeper-notes","lorekeeper-docs"]
to search semantically, or \`mcp__qmd__get\` to fetch a specific file by path.
Pull only what the current task needs — don't bulk-load.

EOF

# Use a printf loop instead of `echo | sed "s|^|...|"` so shellcheck doesn't
# complain about SC2001 (parameter expansion is clearer for a per-line prefix).
emit_listing() {
  local kind="$1" list="$2"
  while IFS= read -r line; do
    printf '  %s/%s/%s\n' "$kind" "$repo" "$line"
  done <<<"$list"
}

if [[ -n "$notes_files" ]]; then
  echo "### notes ($(echo "$notes_files" | wc -l | tr -d ' ') files):"
  emit_listing notes "$notes_files"
  echo
fi

if [[ -n "$docs_files" ]]; then
  echo "### docs ($(echo "$docs_files" | wc -l | tr -d ' ') files):"
  emit_listing docs "$docs_files"
  echo
fi

exit 0

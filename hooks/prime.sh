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
shared_notes_dir="$LOREKEEPER_HOME/notes/shared"

# Staleness: notes with updated/date older than 90 days get a [STALE?] marker.
stale_cutoff="$(date -d "90 days ago" +%Y-%m-%d 2>/dev/null \
  || date -v-90d +%Y-%m-%d 2>/dev/null \
  || echo "")"

get_note_date() {
  local f="$1" d
  d="$(grep -m1 '^updated:' "$f" 2>/dev/null | sed 's/^updated:[[:space:]]*//')"
  [[ -z "$d" ]] && d="$(grep -m1 '^date:' "$f" 2>/dev/null | sed 's/^date:[[:space:]]*//')"
  printf '%s\n' "$d"
}

is_stale() {
  local f="$1" note_date
  [[ -z "$stale_cutoff" ]] && return 1
  note_date="$(get_note_date "$f")"
  [[ -n "$note_date" && "$note_date" < "$stale_cutoff" ]]
}

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
shared_files="$(list_md "$shared_notes_dir")"

if [[ -z "$notes_files" && -z "$docs_files" && -z "$shared_files" ]]; then
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

# Emit listing with optional [STALE?] markers.
emit_listing() {
  local kind="$1" repo_name="$2" list="$3" base_dir="$4"
  while IFS= read -r line; do
    local stale_marker=""
    local note_path="$base_dir/$line"
    if [[ -f "$note_path" ]] && is_stale "$note_path"; then
      stale_marker=" [STALE?]"
    fi
    printf '  %s/%s/%s%s\n' "$kind" "$repo_name" "$line" "$stale_marker"
  done <<<"$list"
}

if [[ -n "$notes_files" ]]; then
  echo "### notes ($(echo "$notes_files" | wc -l | tr -d ' ') files):"
  emit_listing notes "$repo" "$notes_files" "$notes_dir"
  echo
fi

if [[ -n "$shared_files" ]]; then
  echo "### shared notes ($(echo "$shared_files" | wc -l | tr -d ' ') files — cross-repo):"
  emit_listing notes shared "$shared_files" "$shared_notes_dir"
  echo
fi

if [[ -n "$docs_files" ]]; then
  echo "### docs ($(echo "$docs_files" | wc -l | tr -d ' ') files):"
  emit_listing docs "$repo" "$docs_files" "$docs_dir"
  echo
fi

# Distill pending reminder: emitted when 15+ notes written since last distill.
pending_flag="$LOREKEEPER_HOME/.distill-pending/$repo"
if [[ -f "$pending_flag" ]]; then
  cat <<'DISTILL'
> **lorekeeper:** distill pending for this repo — notes have grown significantly since
> last synthesis. Consider running `lorekeeper distill` when this session ends.
DISTILL
  echo
fi

exit 0

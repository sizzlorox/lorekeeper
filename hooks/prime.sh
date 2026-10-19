#!/usr/bin/env bash
# lorekeeper: SessionStart / UserPromptSubmit hook
# Reads cwd from Claude Code's JSON input, resolves the repo name, and emits
# an index of existing notes/docs. stdout becomes additional context.
#
# Safe to run on both hook events — a session-id marker guards against the
# UserPromptSubmit version re-injecting on every message.

set -e

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LOREKEEPER_HOME="${LOREKEEPER_HOME:-$(cat "$CLAUDE_DIR/.lorekeeper-home" 2>/dev/null || echo "$HOME/.local/share/lorekeeper")}"

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

# Resolve repo identity (worktree- and submodule-aware). One shared resolver;
# prefer the sibling lib (canonical hooks + repo checkout), fall back to the
# installed copy (Claude shim lives elsewhere and renames the hook).
_LK_LIB="$(dirname "${BASH_SOURCE[0]:-$0}")/lib/resolve.sh"
[[ -f "$_LK_LIB" ]] || _LK_LIB="$LOREKEEPER_HOME/hooks/lib/resolve.sh"
# shellcheck source=lib/resolve.sh
[[ -f "$_LK_LIB" ]] && . "$_LK_LIB"

repo=""
if [[ -n "$cwd" && -d "$cwd" ]] && command -v lk_resolve >/dev/null 2>&1; then
  lk_resolve "$cwd"
  repo="$LK_KEY"
fi

if [[ -z "$repo" ]]; then
  exit 0  # no cwd / resolver unavailable — nothing to prime
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

# --- cross-boundary hints: one line each, no file listings (token-flat) ---
count_md() { find "$1" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' '; }

parent_line=""
if [[ -n "${LK_PARENT_KEY:-}" ]]; then
  pn="$(count_md "$LOREKEEPER_HOME/notes/$LK_PARENT_KEY")"
  pd="$(count_md "$LOREKEEPER_HOME/docs/$LK_PARENT_KEY")"
  if [[ "$pn" != 0 || "$pd" != 0 ]]; then
    parent_line="parent '$LK_PARENT_KEY': $pn notes, $pd docs — search it if the task crosses the boundary."
  fi
fi

# Superproject session: list submodules that have memory (cap 5). A submodule's
# key is the basename of its path, so no checkout/init is needed to find it.
submod_line=""
if [[ -z "${LK_PARENT_KEY:-}" && -n "${LK_TOPLEVEL:-}" && -f "$LK_TOPLEVEL/.gitmodules" ]]; then
  submods=""; sc=0
  while IFS= read -r sp; do
    [[ -z "$sp" ]] && continue
    sk="$(basename "$sp")"
    stot=$(( $(count_md "$LOREKEEPER_HOME/notes/$sk") + $(count_md "$LOREKEEPER_HOME/docs/$sk") ))
    [[ "$stot" == 0 ]] && continue
    sc=$((sc + 1))
    [[ "$sc" -le 5 ]] && submods="${submods:+$submods, }$sk ($stot)"
  done < <(git -C "$LK_TOPLEVEL" config --file "$LK_TOPLEVEL/.gitmodules" --get-regexp '\.path$' 2>/dev/null | awk '{print $2}')
  [[ -n "$submods" ]] && submod_line="submodules with memory: $submods"
fi

if [[ -z "$notes_files" && -z "$docs_files" && -z "$shared_files" ]]; then
  # No own memory. Emit at most one cross-boundary hint, else stay silent.
  if [[ -n "$parent_line" ]]; then echo "## lorekeeper: $parent_line"
  elif [[ -n "$submod_line" ]]; then echo "## lorekeeper: $submod_line"; fi
  exit 0
fi

# Header suffix only when true (a few tokens, only in those sessions).
hdr_suffix=""
if [[ -n "${LK_PARENT_KEY:-}" ]]; then hdr_suffix=" (submodule of '$LK_PARENT_KEY')"
elif [[ "${LK_IS_WORKTREE:-}" == 1 ]]; then hdr_suffix=" (worktree)"; fi

cat <<EOF
## lorekeeper: repo '$repo'$hdr_suffix

Prior memory exists. Use \`mcp__qmd__query\` with collections=["lorekeeper-notes","lorekeeper-docs"]
to search semantically, or \`mcp__qmd__get\` to fetch a specific file by path.
Pull only what the current task needs — don't bulk-load.

EOF

[[ -n "$parent_line" ]] && { echo "$parent_line"; echo; }
[[ -n "$submod_line" ]] && { echo "$submod_line"; echo; }

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

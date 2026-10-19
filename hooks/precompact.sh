#!/usr/bin/env bash
# lorekeeper: PreCompact hook — inject handoff context into compact prompt.
# stdout → appended to compact prompt. exit 0 = success.
# NO LLM calls. Disk reads only. Must be fast (< 2s).

set -e

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LOREKEEPER_HOME="${LOREKEEPER_HOME:-$(cat "$CLAUDE_DIR/.lorekeeper-home" 2>/dev/null || echo "$HOME/.local/share/lorekeeper")}"

# Off switches
[[ -e "$LOREKEEPER_HOME/.autonote-off" ]] && exit 0
[[ "${LOREKEEPER_AUTONOTE:-on}" == "off" ]] && exit 0

command -v jq  >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

# Read stdin JSON, extract cwd
input="$(cat)"
cwd="$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)"
[[ -z "$cwd" ]] && exit 0

# Resolve repo identity (worktree- and submodule-aware) via the shared resolver.
_LK_LIB="$(dirname "${BASH_SOURCE[0]:-$0}")/lib/resolve.sh"
[[ -f "$_LK_LIB" ]] || _LK_LIB="$LOREKEEPER_HOME/hooks/lib/resolve.sh"
# shellcheck source=lib/resolve.sh
[[ -f "$_LK_LIB" ]] && . "$_LK_LIB"
command -v lk_resolve >/dev/null 2>&1 || exit 0
lk_resolve "$cwd"
[[ -z "$LK_TOPLEVEL" ]] && exit 0   # not a git repo
repo="$LK_KEY"                      # worktrees share one key; submodules keep their own

# --- Handoff rules (always printed) ---
cat << 'RULES'
== LOREKEEPER: HANDOFF CONTEXT ==

When summarizing this session for compaction, please follow these rules:
1. Preserve the WHY behind every decision — not just what was done, but why that approach was chosen and what alternatives were rejected.
2. Keep exact file paths and line numbers that were read or modified.
3. Keep error messages and stack traces verbatim when they informed a diagnosis or fix.
4. State current task status: what is complete, what is in progress, what is blocked and by what.
5. If this context already contains a previous compaction summary (starting with "This session is being continued"), carry its key points forward — do not discard prior history.
6. Preserve any blockers and dependencies between tasks.
RULES

# --- Collect and print notes/docs (if any exist) ---
notes_dir="$LOREKEEPER_HOME/notes/$repo"
docs_dir="$LOREKEEPER_HOME/docs/$repo"

files=()
if [[ -d "$notes_dir" ]]; then
  while IFS= read -r -d '' f; do
    files+=("note:$f")
  done < <(find "$notes_dir" -maxdepth 1 -name '*.md' -type f -print0 2>/dev/null | sort -z)
fi
if [[ -d "$docs_dir" ]]; then
  while IFS= read -r -d '' f; do
    files+=("doc:$f")
  done < <(find "$docs_dir" -maxdepth 1 -name '*.md' -type f -print0 2>/dev/null | sort -z)
fi

if [[ ${#files[@]} -gt 0 ]]; then
  echo ""
  echo "The following notes from previous sessions in this repo may provide relevant context."
  echo "Preserve any insights from these notes that are relevant to the current work:"

  count=0
  max_files=10
  max_chars=1500

  for entry in "${files[@]}"; do
    (( count >= max_files )) && break

    kind="${entry%%:*}"
    filepath="${entry#*:}"
    slug="$(basename "$filepath" .md)"

    content="$(head -c "$max_chars" "$filepath" 2>/dev/null || true)"
    [[ -z "$content" ]] && continue

    echo ""
    echo "### lorekeeper ${kind}: ${slug}"
    echo "$content"

    (( count++ )) || true
  done
fi

exit 0

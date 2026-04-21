#!/usr/bin/env bash
# lorekeeper: PostToolUse hook
# When Claude writes under $LOREKEEPER_HOME, kick off a background reindex so
# the new content is searchable in the next turn. Non-blocking.

set -e

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LOREKEEPER_HOME="$(cat "$CLAUDE_DIR/.lorekeeper-home" 2>/dev/null || echo "$HOME/.local/share/lorekeeper")"

input="$(cat)"
file_path="$(jq -r '.tool_input.file_path // .tool_input.path // empty' <<<"$input" 2>/dev/null)"

[[ -z "$file_path" ]] && exit 0

# Normalize to absolute for the prefix check
case "$file_path" in
  /*) abs="$file_path" ;;
  *)  abs="$(cd "$(dirname "$file_path")" 2>/dev/null && pwd)/$(basename "$file_path")" ;;
esac

# Only reindex if the write landed inside our home
case "$abs" in
  "$LOREKEEPER_HOME"/*) ;;
  *) exit 0 ;;
esac

# Serialize concurrent reindexes with a lock — flock if available, fallback to mkdir
lock_dir="${XDG_RUNTIME_DIR:-/tmp}/lorekeeper"
mkdir -p "$lock_dir"
lock="$lock_dir/reindex.lock"

(
  if command -v flock >/dev/null; then
    exec 9>"$lock"
    flock -n 9 || exit 0
    qmd update && qmd embed
  else
    if mkdir "$lock.d" 2>/dev/null; then
      trap 'rmdir "$lock.d" 2>/dev/null' EXIT
      qmd update && qmd embed
    fi
  fi
) >/dev/null 2>&1 </dev/null &
disown 2>/dev/null || true

exit 0

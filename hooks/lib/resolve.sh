#!/usr/bin/env bash
# lorekeeper repo-identity resolver (POSIX sh / bash).
#
# ONE implementation, shared by every .sh hook and bin/lorekeeper, mirrored by
# resolve.ps1 and resolve.ts. Source it AFTER $LOREKEEPER_HOME is set, then call
# `lk_resolve "$cwd"`. It sets:
#
#   LK_KEY         memory key -> notes/<key>/, docs/<key>/
#   LK_TOPLEVEL    git rev-parse --show-toplevel (the checkout you're in)
#   LK_MAIN        path of the MAIN worktree for this repo
#   LK_IS_WORKTREE 1 if in a linked worktree, 0 if main checkout, "" if non-git
#   LK_PARENT_KEY  key of the superproject if this is a submodule, else ""
#   LK_SUB_PATH    submodule path relative to the superproject, else ""
#
# Non-git dir: LK_KEY=basename(cwd), everything else empty (today's prime.sh
# fallback). Key is backward-compatible: for a main checkout LK_MAIN == toplevel,
# so basename(main) == today's basename(toplevel) for every existing repo.
#
# Requires git >= 2.13 (rev-parse --absolute-git-dir, --show-superproject-working-tree).
# Deliberately avoids --path-format (needs git 2.31). Never calls exit; returns 0.

# __lk_base <dir> -> basename of <dir>, canonicalized so "." / trailing-slash work.
__lk_base() { basename "$(cd "$1" 2>/dev/null && pwd -P || printf '%s' "$1")"; }

# lk_key <dir> -> echoes the memory key for <dir> (basename(cwd) if non-git).
# Self-contained so it can resolve a superproject without touching LK_* globals.
lk_key() {
  local dir __top __ovr __agd __wl __main __second __leaf
  dir="$1"
  __top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$__top" ]; then __lk_base "$dir"; return 0; fi
  # Collision escape hatch; lives in common config, so all worktrees share it.
  __ovr="$(git -C "$dir" config --get lorekeeper.key 2>/dev/null || true)"
  if [ -n "$__ovr" ]; then printf '%s\n' "$__ovr"; return 0; fi
  __agd="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null || true)"
  if [ -n "$__agd" ] && [ -f "$__agd/commondir" ]; then
    # Linked worktree: first porcelain entry is the MAIN worktree.
    __wl="$(git -C "$dir" worktree list --porcelain 2>/dev/null || true)"
    __main="$(printf '%s\n' "$__wl" | sed -n '1s/^worktree //p')"
    __second="$(printf '%s\n' "$__wl" | sed -n '2p')"
    __leaf="$(basename "$__main")"
    if [ "$__second" = "bare" ]; then
      # Bare repo: strip .git (app.git -> app); for a ".bare"/".git" dir use its parent.
      case "$__leaf" in
        .git|.bare) basename "$(dirname "$__main")" ;;
        *)          printf '%s\n' "${__leaf%.git}" ;;
      esac
    else
      printf '%s\n' "$__leaf"
    fi
  else
    basename "$__top"
  fi
}

# lk_resolve <dir> -> sets the LK_* globals described above.
lk_resolve() {
  local dir __top __agd __super
  dir="$1"
  LK_KEY=""; LK_TOPLEVEL=""; LK_MAIN=""; LK_IS_WORKTREE=""; LK_PARENT_KEY=""; LK_SUB_PATH=""
  __top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$__top" ]; then
    LK_KEY="$(__lk_base "$dir")"
    return 0
  fi
  LK_TOPLEVEL="$__top"
  LK_KEY="$(lk_key "$dir")"
  __agd="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null || true)"
  if [ -n "$__agd" ] && [ -f "$__agd/commondir" ]; then
    LK_IS_WORKTREE=1
    LK_MAIN="$(git -C "$dir" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
  else
    LK_IS_WORKTREE=0
    LK_MAIN="$__top"
  fi
  __super="$(git -C "$__top" rev-parse --show-superproject-working-tree 2>/dev/null || true)"
  if [ -n "$__super" ]; then
    LK_PARENT_KEY="$(lk_key "$__super")"
    LK_SUB_PATH="${__top#"$__super"/}"
  fi
  return 0
}

# Direct-exec mode (parity harness): print the fields for <dir|.> as key=value lines.
if [ "${BASH_SOURCE:-$0}" = "$0" ]; then
  lk_resolve "${1:-.}"
  printf 'key=%s\n' "$LK_KEY"
  printf 'toplevel=%s\n' "$LK_TOPLEVEL"
  printf 'main=%s\n' "$LK_MAIN"
  printf 'is_worktree=%s\n' "$LK_IS_WORKTREE"
  printf 'parent_key=%s\n' "$LK_PARENT_KEY"
  printf 'sub_path=%s\n' "$LK_SUB_PATH"
fi

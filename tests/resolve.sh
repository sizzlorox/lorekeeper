#!/usr/bin/env bash
# Parity + correctness tests for the repo-identity resolver.
# Builds git fixtures in a temp dir and runs every available runtime
# (resolve.sh always; resolve.ps1 via powershell/pwsh; resolve.ts via bun)
# against ONE expected table. Asserts key / is_worktree / parent_key / sub_path.
#
# Usage: bash tests/resolve.sh        (exits non-zero on any failure)
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RS="$REPO_ROOT/hooks/lib/resolve.sh"
RP="$REPO_ROOT/hooks/lib/resolve.ps1"
RT="$REPO_ROOT/omp-plugin/src/resolve.ts"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
GC() { git -c user.email=a@b.c -c user.name=x -c protocol.file.allow=always "$@"; }
mkrepo() { mkdir -p "$1"; ( cd "$1" && GC init -q && GC commit -q --allow-empty -m init ); }

# ---- runtimes available? ----
PWSH=""
command -v pwsh >/dev/null 2>&1 && PWSH="pwsh"
[ -z "$PWSH" ] && command -v powershell >/dev/null 2>&1 && PWSH="powershell"
BUN=""
command -v bun >/dev/null 2>&1 && BUN="bun"

# field <output> <name> -> prints value of key=value line
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

PASS=0; FAIL=0
# assert_runtime <runtime-label> <output> <ekey> <eiw> <eparent> <esub>
assert_runtime() {
  local rt="$1" out="$2" ek="$3" eiw="$4" ep="$5" es="$6"
  local gk gi gp gs ok=1
  gk="$(field "$out" key)"; gi="$(field "$out" is_worktree)"
  gp="$(field "$out" parent_key)"; gs="$(field "$out" sub_path)"
  [ "$gk" = "$ek" ] || ok=0
  [ "$gi" = "$eiw" ] || ok=0
  [ "$gp" = "$ep" ] || ok=0
  [ "$gs" = "$es" ] || ok=0
  if [ "$ok" = 1 ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    printf 'FAIL [%s] %s\n  expected: key=%s iw=%s parent=%s sub=%s\n  got:      key=%s iw=%s parent=%s sub=%s\n' \
      "$rt" "$CASE" "$ek" "$eiw" "$ep" "$es" "$gk" "$gi" "$gp" "$gs" >&2
  fi
}

# check <label> <dir> <ekey> <eiw> <eparent> <esub>
check() {
  CASE="$1"; local dir="$2" ek="$3" eiw="$4" ep="$5" es="$6"
  assert_runtime "sh" "$(bash "$RS" "$dir")" "$ek" "$eiw" "$ep" "$es"
  if [ -n "$PWSH" ]; then
    assert_runtime "ps1" "$("$PWSH" -NoProfile -ExecutionPolicy Bypass -File "$RP" "$dir" 2>/dev/null)" "$ek" "$eiw" "$ep" "$es"
  fi
  if [ -n "$BUN" ]; then
    assert_runtime "ts" "$("$BUN" "$RT" "$dir" 2>/dev/null)" "$ek" "$eiw" "$ep" "$es"
  fi
}

# ---- build fixtures ----
mkrepo "$TMP/app"; mkdir -p "$TMP/app/src/deep"
( cd "$TMP/app" && GC worktree add -q "$TMP/app-feat" HEAD >/dev/null 2>&1 )

GC init -q --bare "$TMP/app.git"
GC clone -q "$TMP/app.git" "$TMP/seed" >/dev/null 2>&1
( cd "$TMP/seed" && GC commit -q --allow-empty -m init && GC push -q origin HEAD:main >/dev/null 2>&1 )
( cd "$TMP/app.git" && GC worktree add -q "$TMP/wt1" main >/dev/null 2>&1 )

mkdir -p "$TMP/proj"
GC init -q --bare "$TMP/proj/.bare"
GC clone -q "$TMP/proj/.bare" "$TMP/seed2" >/dev/null 2>&1
( cd "$TMP/seed2" && GC commit -q --allow-empty -m init && GC push -q origin HEAD:main >/dev/null 2>&1 )
( cd "$TMP/proj/.bare" && GC worktree add -q "$TMP/proj/main" main >/dev/null 2>&1 )

mkrepo "$TMP/sub-src"; mkrepo "$TMP/super"
( cd "$TMP/super" && GC submodule add -q "$TMP/sub-src" libs/core >/dev/null 2>&1 && GC commit -q -m addsub )
mkdir -p "$TMP/super/libs/core/x"

mkrepo "$TMP/sub-src2"; mkrepo "$TMP/super2"
( cd "$TMP/super2" && GC submodule add --name core-lib -q "$TMP/sub-src2" libs/core >/dev/null 2>&1 && GC commit -q -m addsub )

( cd "$TMP/super" && GC worktree add -q "$TMP/super-feat" HEAD >/dev/null 2>&1 )
( cd "$TMP/super-feat" && GC submodule update --init -q >/dev/null 2>&1 )

( cd "$TMP/super/libs/core" && GC worktree add -q "$TMP/core-wt" HEAD >/dev/null 2>&1 )

mkrepo "$TMP/ovr"
( cd "$TMP/ovr" && GC config lorekeeper.key app-acme && GC worktree add -q "$TMP/ovr-feat" HEAD >/dev/null 2>&1 )

mkdir -p "$TMP/plain/x"

# ---- expected table:        label                     dir                    key       iw parent  sub ----
check "1 plain"                "$TMP/app/src/deep"       app       0  ""      ""
check "2 worktree"             "$TMP/app-feat"           app       1  ""      ""
check "3 bare-wt"              "$TMP/wt1"                app       1  ""      ""
check "3b .bare-layout-wt"     "$TMP/proj/main"          proj      1  ""      ""
check "4 submodule"            "$TMP/super/libs/core/x"  core      0  super   libs/core
check "4b submodule-name!=path" "$TMP/super2/libs/core"  core      0  super2  libs/core
check "5 super-wt/submodule"   "$TMP/super-feat/libs/core" core    0  super   libs/core
# Fixture 6: a worktree of a submodule reports NO superproject (git limitation),
# so parent_key is empty — asserting git's actual behavior, not working around it.
check "6 worktree-of-submodule" "$TMP/core-wt"           core      1  ""      ""
check "7 override"             "$TMP/ovr"                app-acme  0  ""      ""
check "7b override-from-wt"    "$TMP/ovr-feat"           app-acme  1  ""      ""
check "8 non-git"              "$TMP/plain/x"            x         ""  ""     ""

echo "----"
echo "runtimes: sh${PWSH:+ + ps1}${BUN:+ + ts}"
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]

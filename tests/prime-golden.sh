#!/usr/bin/env bash
# Backward-compat guard: prime.sh output for a PLAIN repo must stay byte-identical
# across the resolver refactor. Builds a deterministic fixture home + git repo,
# runs prime.sh, and diffs against tests/golden/prime-plain.txt.
#
#   bash tests/prime-golden.sh               # verify (exit 1 on drift)
#   UPDATE_GOLDEN=1 bash tests/prime-golden.sh   # (re)capture the golden
set -u
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRIME="$REPO_ROOT/hooks/prime.sh"
PRIME_PS1="$REPO_ROOT/hooks/prime.ps1"
GOLDEN="$REPO_ROOT/tests/golden/prime-plain.txt"
PWSH=""
command -v pwsh >/dev/null 2>&1 && PWSH="pwsh"
[ -z "$PWSH" ] && command -v powershell >/dev/null 2>&1 && PWSH="powershell"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

HOME_DIR="$TMP/home"
REPO="$TMP/goldrepo"
mkdir -p "$REPO"
( cd "$REPO" && git -c user.email=a@b.c -c user.name=x init -q && \
  git -c user.email=a@b.c -c user.name=x commit -q --allow-empty -m init )

mkdir -p "$HOME_DIR/notes/goldrepo" "$HOME_DIR/docs/goldrepo" \
         "$HOME_DIR/notes/shared" "$HOME_DIR/.distill-pending"
cat > "$HOME_DIR/notes/goldrepo/fresh.md" <<'EOF'
---
type: note
updated: 2999-01-01
---
# fresh
EOF
cat > "$HOME_DIR/notes/goldrepo/stale.md" <<'EOF'
---
type: note
updated: 2000-01-01
---
# stale
EOF
cat > "$HOME_DIR/docs/goldrepo/arch.md" <<'EOF'
---
type: doc
updated: 2999-01-01
---
# arch
EOF
cat > "$HOME_DIR/notes/shared/team.md" <<'EOF'
---
type: note
updated: 2999-01-01
---
# team
EOF
: > "$HOME_DIR/.distill-pending/goldrepo"

OUT="$(printf '{"cwd":"%s"}' "$REPO" | LOREKEEPER_HOME="$HOME_DIR" bash "$PRIME")"

if [ "${UPDATE_GOLDEN:-}" = "1" ]; then
  mkdir -p "$(dirname "$GOLDEN")"
  printf '%s\n' "$OUT" > "$GOLDEN"
  echo "golden updated: $GOLDEN"
  exit 0
fi

if [ ! -f "$GOLDEN" ]; then
  echo "no golden file; run: UPDATE_GOLDEN=1 bash tests/prime-golden.sh" >&2
  exit 1
fi

rc=0
if diff -u "$GOLDEN" <(printf '%s\n' "$OUT"); then
  echo "prime-golden[sh]: OK"
else
  echo "prime-golden[sh]: DRIFT (plain-repo prime.sh output changed)" >&2
  rc=1
fi

# PowerShell parity: prime.ps1 must produce the same plain-repo output (ignoring CRLF).
# Windows PowerShell needs real Windows paths; cygpath -m gives C:/... (JSON-safe,
# Test-Path-safe). Skip gracefully where cygpath is unavailable (non-Windows CI).
if [ -n "$PWSH" ] && command -v cygpath >/dev/null 2>&1; then
  REPO_W="$(cygpath -m "$REPO")"; HOME_W="$(cygpath -m "$HOME_DIR")"
  PSOUT="$(printf '{"cwd":"%s"}' "$REPO_W" | LOREKEEPER_HOME="$HOME_W" \
    "$PWSH" -NoProfile -ExecutionPolicy Bypass -File "$PRIME_PS1" 2>/dev/null | tr -d '\r')"
  # Windows PowerShell 5.1 reads UTF-8-no-BOM source as ANSI and mangles the em
  # dash (pre-existing, platform-specific; pwsh 7+ is fine). Normalize —/- on both
  # sides so this guards structure, not that quirk.
  if diff -u <(sed 's/—/-/g' "$GOLDEN") <(printf '%s\n' "$PSOUT" | sed 's/—/-/g'); then
    echo "prime-golden[ps1]: OK"
  else
    echo "prime-golden[ps1]: DRIFT (plain-repo prime.ps1 output differs from golden)" >&2
    rc=1
  fi
fi
exit $rc

#!/usr/bin/env bash
# Register lorekeeper directories with qmd as two collections and attach
# collection-level contexts. Idempotent — safe to re-run.

set -e

LOREKEEPER_HOME="${1:-${LOREKEEPER_HOME:-$HOME/.local/share/lorekeeper}}"

say()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }

mkdir -p "$LOREKEEPER_HOME/notes" "$LOREKEEPER_HOME/docs"

register_collection() {
  local name="$1" path="$2"
  if qmd collection list 2>/dev/null | grep -qE "^[[:space:]]*$name([[:space:]]|$)"; then
    return 0
  fi
  say "adding qmd collection: $name -> $path"
  qmd collection add "$path" --name "$name" --mask "**/*.md"
}

register_collection "lorekeeper-notes" "$LOREKEEPER_HOME/notes"
register_collection "lorekeeper-docs"  "$LOREKEEPER_HOME/docs"

# Root-level contexts describing the collection purposes
qmd context add "qmd://lorekeeper-notes" \
  "Session-to-session memory per repo — gotchas, decisions, debugging dead-ends, non-obvious behavior. Written in caveman-speak when caveman is active. Slug files under notes/<repo>/*.md." \
  2>/dev/null || true

qmd context add "qmd://lorekeeper-docs" \
  "Durable reference docs per repo — overview, architecture, runbook, conventions. docs/<repo>/*.md. Stable, polished, handed to new teammates." \
  2>/dev/null || true

say "qmd collections ready"

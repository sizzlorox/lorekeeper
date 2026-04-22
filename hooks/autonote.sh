#!/usr/bin/env bash
# lorekeeper: SessionEnd hook — autonomous note extraction.
# Gates cheaply, then asks Haiku if the session was note-worthy, then asks
# Sonnet to draft the note. Runs detached so SessionEnd returns fast.

set -e

# Recursion guard — skip when we're inside a classifier claude -p call.
[[ "${LOREKEEPER_AUTONOTE_CHILD:-}" == "1" ]] && exit 0

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LOREKEEPER_HOME="$(cat "$CLAUDE_DIR/.lorekeeper-home" 2>/dev/null || echo "$HOME/.local/share/lorekeeper")"
LOG="$LOREKEEPER_HOME/.autonote.log"

# Off switches
[[ -e "$LOREKEEPER_HOME/.autonote-off" ]] && exit 0
[[ "${LOREKEEPER_AUTONOTE:-on}" == "off" ]] && exit 0

command -v claude >/dev/null 2>&1 || exit 0
command -v jq     >/dev/null 2>&1 || exit 0

input="$(cat)"
transcript_path="$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null)"
cwd="$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)"
session_id="$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)"

[[ -z "$transcript_path" || ! -f "$transcript_path" ]] && exit 0
[[ -z "$cwd" || ! -d "$cwd" ]] && exit 0

toplevel="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -z "$toplevel" ]] && exit 0
repo="$(basename "$toplevel")"

# Dedup: never classify the same session twice.
seen_dir="$LOREKEEPER_HOME/.autonote-seen"
mkdir -p "$seen_dir"
[[ -n "$session_id" && -e "$seen_dir/$session_id" ]] && exit 0
[[ -n "$session_id" ]] && : > "$seen_dir/$session_id"
find "$seen_dir" -type f -mtime +30 -delete 2>/dev/null || true

# Detach: SessionEnd has a ~60s timeout and Sonnet calls run longer.
(
  # --- structural gate ---
  tool_count="$(jq -s '[.[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")] | length' "$transcript_path" 2>/dev/null || echo 0)"
  [[ "$tool_count" -lt 10 ]] && exit 0

  # --- signal gate ---
  if ! grep -qiE "(error|exception|failed|traceback|turns out|instead|because|decided|doesn.t work|won.t work|gotcha|workaround|non.obvious|unexpected|surprise)" "$transcript_path"; then
    exit 0
  fi

  # --- condense transcript ---
  # Keep user/assistant text + tool names. Drop tool results (noisy, large).
  condensed="$(mktemp)"
  trap 'rm -f "$condensed"' EXIT

  jq -r '
    select(.type == "user" or .type == "assistant") |
    (.message.content // empty) as $c |
    if ($c | type) == "string" then
      "[" + .type + "] " + $c
    elif ($c | type) == "array" then
      "[" + .type + "] " + (
        [$c[] |
          if .type == "text" then .text
          elif .type == "tool_use" then "<tool:" + (.name // "?") + ">"
          else "" end
        ] | map(select(. != "")) | join(" ")
      )
    else empty end
  ' "$transcript_path" | head -c 60000 > "$condensed"

  [[ ! -s "$condensed" ]] && exit 0

  # --- Haiku gate ---
  gate_prompt='You classify Claude Code session transcripts for NOTE-WORTHINESS.

Note-worthy = the session produced non-obvious knowledge a future session would benefit from:
- a debugging dead-end that cost >15 min with a non-obvious fix
- a library/API/system that behaved unexpectedly and required digging
- an architectural decision with reasoning
- a config/env var/secret in a non-obvious location
- an undocumented team convention

NOT note-worthy: quick lookups, pure codegen, formatting fixes, trivial Q&A, anything already covered by the repo README.

Reply with EXACTLY "yes" or "no" on the first line. Nothing else.

TRANSCRIPT:
'
  gate_input="${gate_prompt}$(cat "$condensed")"
  gate="$(LOREKEEPER_AUTONOTE_CHILD=1 claude -p "$gate_input" \
      --model claude-haiku-4-5-20251001 \
      --tools "" 2>/dev/null \
    | awk 'NR==1 {print tolower($1); exit}' | tr -cd 'a-z')"

  [[ "$gate" != "yes" ]] && exit 0

  # --- Sonnet draft ---
  today="$(date +%Y-%m-%d)"
  draft_prompt="Extract the single most memory-worthy learning from the following Claude Code session as a note. Output ONLY the note contents, no preamble, no code fence. Exact format:

---
repo: $repo
topic: <2-5 words>
date: $today
tags: [<tag>, <tag>]
slug: <kebab-case-slug>
---

# <Title>

## context
<1-3 sentences: when/why this came up>

## what i learned
<bullets for gotchas. cite file:line where relevant. prose terse: drop articles, fragments ok. technical identifiers and error strings exact.>

## see also
<related files or external refs; omit section entirely if none>

Rules:
- Pick ONE specific learning. Best candidates: debug dead-end + fix, non-obvious API behavior, design decision + reasoning, config in odd location.
- If NOTHING is truly non-obvious or worth remembering cross-session, output literally: SKIP
- slug must be filesystem-safe kebab-case, no spaces.

TRANSCRIPT:
"

  draft_input="${draft_prompt}$(cat "$condensed")"
  draft="$(LOREKEEPER_AUTONOTE_CHILD=1 claude -p "$draft_input" \
      --model claude-sonnet-4-6 \
      --tools "" 2>/dev/null)"

  [[ -z "$draft" ]] && exit 0
  first_line="$(printf '%s' "$draft" | head -1 | tr -d '[:space:]')"
  [[ "$first_line" == "SKIP" ]] && exit 0

  # Extract slug from first frontmatter block
  slug="$(printf '%s\n' "$draft" \
    | awk 'BEGIN{fm=0} /^---$/ {fm++; next} fm==1 && /^slug:/ {sub(/^slug:[[:space:]]*/,""); print; exit}' \
    | tr -cd 'A-Za-z0-9_-')"
  [[ -z "$slug" ]] && slug="auto-$(date +%s)"

  notes_dir="$LOREKEEPER_HOME/notes/$repo"
  mkdir -p "$notes_dir"
  note_path="$notes_dir/$slug.md"
  [[ -e "$note_path" ]] && note_path="$notes_dir/$slug-$(date +%s).md"

  # Drop the slug: line from frontmatter before writing (not part of canonical format).
  printf '%s\n' "$draft" \
    | awk 'BEGIN{fm=0} /^---$/ {fm++; print; next} fm==1 && /^slug:/ {next} {print}' \
    > "$note_path"

  # Trigger reindex directly — PostToolUse doesn't fire for non-Claude writes.
  (qmd update && qmd embed) >/dev/null 2>&1 || true

  mkdir -p "$(dirname "$LOG")"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $repo: auto-wrote $note_path (session $session_id)" >> "$LOG"
) >/dev/null 2>&1 </dev/null &
disown 2>/dev/null || true

exit 0

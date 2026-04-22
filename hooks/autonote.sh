#!/usr/bin/env bash
# lorekeeper: SessionEnd hook — autonomous extraction.
# Structural gate -> Haiku 4-way classifier -> Sonnet drafter routes to
# notes/, docs/<feature>.md, or docs/adr/ADR-NNNN-<slug>.md.

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
  if ! grep -qiE "(error|exception|failed|traceback|turns out|instead|because|decided|doesn.t work|won.t work|gotcha|workaround|non.obvious|unexpected|surprise|shipped|done|finished|works now|ready|implemented|built)" "$transcript_path"; then
    exit 0
  fi

  # --- condense transcript ---
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

  # --- Haiku classifier ---
  gate_prompt='You classify finished Claude Code sessions. Reply with EXACTLY ONE WORD on line 1: none, note, feature-doc, or adr.

- note: scratch memory for a SINGLE non-obvious learning — debug dead-end + fix, library/API quirk, config in an odd place, undocumented convention. Not ongoing.
- feature-doc: the session BUILT or substantially modified a nameable feature/subsystem future teammates would need onboarding docs for. Strong signal: new files/modules, components wired together, "shipped"/"done"/"works now" language, tests added.
- adr: an architectural or design DECISION was made with reasoning that will constrain future work. Strong signal: alternatives weighed, tradeoffs discussed, decision rationale articulated.
- none: nothing worth preserving cross-session (quick lookup, pure formatting, trivial Q&A).

Default to none unless clear. Between note and feature-doc, prefer note. Return ONE WORD on line 1, nothing else.

TRANSCRIPT:
'
  gate_input="${gate_prompt}$(cat "$condensed")"
  gate="$(LOREKEEPER_AUTONOTE_CHILD=1 claude -p "$gate_input" \
      --model claude-haiku-4-5-20251001 \
      --tools "" 2>/dev/null \
    | awk 'NR==1 {gsub(/[[:space:]]/,""); print tolower($0); exit}' | tr -cd 'a-z-')"

  case "$gate" in
    note)        kind=note ;;
    feature-doc|featuredoc) kind=feature-doc ;;
    adr)         kind=adr ;;
    *)           exit 0 ;;
  esac

  today="$(date +%Y-%m-%d)"

  # --- collect per-kind context + build prompt ---
  case "$kind" in
    note)
      out_dir="$LOREKEEPER_HOME/notes/$repo"
      mkdir -p "$out_dir"
      # Pull existing notes so Sonnet can merge same-topic instead of fork.
      # Cap each to 3KB to keep prompt size sane.
      existing_context=""
      while IFS= read -r -d '' f; do
        bn="$(basename "$f" .md)"
        existing_context+="### existing note: $bn
$(head -c 3000 "$f")

"
      done < <(find "$out_dir" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null)

      draft_prompt="Extract the single most memory-worthy learning from the following Claude Code session as a note. Output ONLY the note contents, no preamble, no code fence.

Existing notes for this repo are below — if this session EXTENDS one of them (same topic/subsystem), reuse its slug and MERGE (preserve existing bullets, add new ones, bump 'updated'). If this session surfaced a NEW learning, pick a fresh slug.

${existing_context:-(no existing notes)}

Exact format:

---
repo: $repo
topic: <2-5 words>
date: <YYYY-MM-DD of first version; reuse from existing if merging, else $today>
updated: $today
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
- If nothing is truly non-obvious, output literally: SKIP
- slug must be filesystem-safe kebab-case, stable across updates.
- When merging, KEEP existing bullets that are still accurate; don't drop unless contradicted.

TRANSCRIPT:
"
      ;;

    feature-doc)
      out_dir="$LOREKEEPER_HOME/docs/$repo"
      mkdir -p "$out_dir"
      # Pull existing feature docs (excluding ADRs) so Sonnet can merge instead
      # of fork. Cap each to 3KB to keep prompt size sane.
      existing_context=""
      while IFS= read -r -d '' f; do
        bn="$(basename "$f" .md)"
        existing_context+="### existing doc: $bn
$(head -c 3000 "$f")

"
      done < <(find "$out_dir" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null)

      draft_prompt="Write engineering feature documentation for the work done in this Claude Code session. Output ONLY the doc contents, no preamble, no code fence.

Existing feature docs for this repo are below — if this session EXTENDED one of them, reuse its slug and MERGE (preserve existing prose, add new sections/details, bump 'updated'). If this session built something NEW, pick a fresh slug.

${existing_context:-(no existing feature docs)}

Exact output format:

---
repo: $repo
type: feature
feature: <human-readable name>
date: <YYYY-MM-DD of first version; reuse from existing if merging, else $today>
updated: $today
slug: <kebab-case-slug>
---

# <Feature Name>

## overview
<1-2 paragraphs: what it does, who uses it, why it exists>

## how it works
<entry points, key files, control flow. cite code as \`path:line\`>

## configuration
<env vars, settings, flags, defaults. omit section if none.>

## usage
<code examples, CLI invocations, API calls>

## see also
<related docs, external refs, code paths. omit section if none.>

Rules:
- If this session did NOT build or substantially modify a nameable feature, output literally: SKIP
- slug must be filesystem-safe kebab-case and stable across updates.
- When merging with existing, KEEP content that's still accurate; don't drop sections unless contradicted.

TRANSCRIPT:
"
      ;;

    adr)
      out_dir="$LOREKEEPER_HOME/docs/$repo/adr"
      mkdir -p "$out_dir"
      last_num="$(find "$out_dir" -maxdepth 1 -type f -name 'ADR-*.md' 2>/dev/null \
        | sed -E 's|.*/ADR-0*([0-9]+).*|\1|' | sort -n | tail -1)"
      next_num="$(( ${last_num:-0} + 1 ))"
      adr_num="$(printf 'ADR-%04d' "$next_num")"

      draft_prompt="Write an Architecture Decision Record (ADR) for the decision made in this Claude Code session. Output ONLY the ADR contents, no preamble, no code fence. Exact format:

---
repo: $repo
type: adr
number: $adr_num
date: $today
status: accepted
slug: <kebab-case-slug>
---

# $adr_num: <Title>

## context
<forces at play, constraints, problem statement. 2-4 sentences.>

## decision
<what was decided, plainly stated>

## consequences
<positive outcomes, negative outcomes, tradeoffs. bullets ok.>

## alternatives considered
<other options evaluated, reasons rejected. bullets ok.>

Rules:
- If this session did NOT make a real architectural decision with reasoning, output literally: SKIP
- slug kebab-case, no spaces. Title short (5-10 words).

TRANSCRIPT:
"
      ;;
  esac

  draft_input="${draft_prompt}$(cat "$condensed")"
  draft="$(LOREKEEPER_AUTONOTE_CHILD=1 claude -p "$draft_input" \
      --model claude-sonnet-4-6 \
      --tools "" 2>/dev/null)"

  [[ -z "$draft" ]] && exit 0
  first_line="$(printf '%s' "$draft" | head -1 | tr -d '[:space:]')"
  [[ "$first_line" == "SKIP" ]] && exit 0

  slug="$(printf '%s\n' "$draft" \
    | awk 'BEGIN{fm=0} /^---$/ {fm++; next} fm==1 && /^slug:/ {sub(/^slug:[[:space:]]*/,""); print; exit}' \
    | tr -cd 'A-Za-z0-9_-')"
  [[ -z "$slug" ]] && slug="auto-$(date +%s)"

  mkdir -p "$out_dir"

  # Per-kind target path + collision handling.
  case "$kind" in
    note)
      # Overwrite on slug match — Sonnet was shown existing content and told to merge.
      out_path="$out_dir/$slug.md"
      ;;
    feature-doc)
      # Overwrite on slug match — Sonnet was shown existing content and told to merge.
      out_path="$out_dir/$slug.md"
      ;;
    adr)
      out_path="$out_dir/$adr_num-$slug.md"
      ;;
  esac

  # Drop the slug: line from frontmatter before writing.
  printf '%s\n' "$draft" \
    | awk 'BEGIN{fm=0} /^---$/ {fm++; print; next} fm==1 && /^slug:/ {next} {print}' \
    > "$out_path"

  (qmd update && qmd embed) >/dev/null 2>&1 || true

  mkdir -p "$(dirname "$LOG")"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $repo [$kind]: $out_path (session $session_id)" >> "$LOG"
) >/dev/null 2>&1 </dev/null &
disown 2>/dev/null || true

exit 0

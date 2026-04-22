## lorekeeper — per-repo cross-session memory

Two qmd collections. `<repo>` = basename of git toplevel.

- `lorekeeper-notes` → `__LOREKEEPER_HOME__/notes/<repo>/*.md` (scratch memory)
- `lorekeeper-docs`  → `__LOREKEEPER_HOME__/docs/<repo>/*.md`  (reference docs)

### read

Before non-trivial task in git repo:

1. Check SessionStart index. Empty → skip. Nothing there, nothing to read.
2. Relevant files listed → `mcp__qmd__query` with `collections: ["lorekeeper-notes", "lorekeeper-docs"]`. Semantic search.
3. `mcp__qmd__get` specific files only. No bulk load.

### write

SessionEnd hook auto-classifies finished session. Routes:
- `note`        → `notes/<repo>/<slug>.md` (scratch gotcha/decision)
- `feature-doc` → `docs/<repo>/<slug>.md`  (completed feature)
- `adr`         → `docs/<repo>/adr/ADR-NNNN-<slug>.md` (decision record)

No mid-session decision needed. Write inline only on explicit user request
("remember X", "document Y feature", "record this decision"). Use format
below for notes; for feature docs and ADRs read an existing neighbor first.

Multi-doc reference (architecture/onboarding/runbook/conventions/api) = on
demand via `lorekeeper distill`. Not this hook's job. Point user at it if
they ask for those.

### note format

Path: `__LOREKEEPER_HOME__/notes/<repo>/<kebab-slug>.md`

```
---
repo: <repo>
topic: <short>
date: <YYYY-MM-DD first version>
updated: <YYYY-MM-DD>
tags: [<tag>]
---

# <Title>

## context
<when/why — 1-3 sentences>

## what i learned
<content. bullets for gotchas. refs as file:line>

## see also
<relative links or qmd:// refs>
```

Prose in notes: caveman-style. Technical strings untouched.

### update

- Edit existing over duplicate.
- Wrong note → correct in place, add dated line under `## revisions`. No stale claims.
- On update, name the file in response. User confirms.

### docs vs notes

`lorekeeper-docs/<repo>/` = hand to new teammate. `overview.md`, `architecture.md`, `runbook.md`, `conventions.md`. Update in place, no dated variants.

Notes = scratch. Docs = polished.

### mechanics

- SessionEnd autonote: heuristic gate → Haiku classify → Sonnet draft. Disable
  via `touch __LOREKEEPER_HOME__/.autonote-off` or `LOREKEEPER_AUTONOTE=off`.
- No manual `qmd update` or `qmd embed`. PostToolUse hook auto-reindex.
- First write auto-registers generic qmd context. Replace later via
  `qmd context add qmd://lorekeeper-notes/<repo> "<summary>"`.
- User says "don't write notes" → honor for session.

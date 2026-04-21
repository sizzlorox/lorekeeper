## lorekeeper — per-repo cross-session memory

Two qmd collections. `<repo>` = basename of git toplevel.

- `lorekeeper-notes` → `__LOREKEEPER_HOME__/notes/<repo>/*.md` (scratch memory)
- `lorekeeper-docs`  → `__LOREKEEPER_HOME__/docs/<repo>/*.md`  (reference docs)

### read

Before non-trivial task in git repo:

1. Check SessionStart index. Empty → skip. Nothing there, nothing to read.
2. Relevant files listed → `mcp__qmd__query` with `collections: ["lorekeeper-notes", "lorekeeper-docs"]`. Semantic search.
3. `mcp__qmd__get` specific files only. No bulk load.

### write — create note when

- Debug dead-end >15 min, answer non-obvious
- Library/API/system behaved non-obviously, required digging
- Architectural/design decision made — record decision AND reasoning
- Config/env/secret in non-obvious location
- Team convention not documented in repo
- Recurring incident pattern with known fix

### write — do NOT create note for

- Session summaries. Memory ≠ journal.
- Already in README/CONTRIBUTING/comments/docstrings. Link, don't restate.
- Trivia faster to re-derive than retrieve.

### note format

Path: `__LOREKEEPER_HOME__/notes/<repo>/<kebab-slug>.md`

```
---
repo: <repo>
topic: <short>
date: <YYYY-MM-DD>
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

- No manual `qmd update` or `qmd embed`. PostToolUse hook auto-reindex.
- User says "don't write notes" → skip write policy for session.

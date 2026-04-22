## lorekeeper — cross-session memory per repo

Two collections of personal memory, organized by the basename of the current
git toplevel (`<repo-name>`):

- `lorekeeper-notes` — scratch memory under `__LOREKEEPER_HOME__/notes/<repo-name>/*.md`
- `lorekeeper-docs`  — durable reference docs under `__LOREKEEPER_HOME__/docs/<repo-name>/*.md`

### Read policy

Before starting any non-trivial task in a git repo:

1. Look at the index injected at `SessionStart` — it lists what memory exists
   for this repo. If nothing is listed, there's nothing to read; proceed.
2. If the index shows relevant-sounding files, run `mcp__qmd__query` scoped to
   `collections: ["lorekeeper-notes", "lorekeeper-docs"]` using task-relevant
   terms. Prefer semantic over keyword search.
3. Fetch only the specific files you intend to use with `mcp__qmd__get`. Don't
   bulk-load the whole index into context.

### Write policy

A `SessionEnd` hook classifies each finished session and autonomously writes
one of:

- `notes/<repo>/<slug>.md` — scratch memory for a non-obvious learning
- `docs/<repo>/<slug>.md` — feature documentation (overview, how it works, config, usage)
- `docs/<repo>/adr/ADR-NNNN-<slug>.md` — architecture decision record

You do not decide mid-session whether to write. The only time to write inline
is when the user explicitly asks you ("remember that…", "write up the …
feature", "record this decision"). Use the note format below for quick
memories; for feature docs and ADRs, read an existing neighbor under
`__LOREKEEPER_HOME__/docs/<repo>/` first to match style.

### Note format

Path: `__LOREKEEPER_HOME__/notes/<repo-name>/<kebab-slug>.md`

```
---
repo: <repo-name>
topic: <short topic>
date: <YYYY-MM-DD>
tags: [<tag>, <tag>]
---

# <Title>

## Context
<When/why this came up — 1-3 sentences.>

## What I learned
<The actual content. Bullets for gotchas. Code refs as file:line.>

## See also
<Relative links to related notes, or qmd:// references.>
```

### Update policy

- Prefer editing an existing note over creating a near-duplicate.
- If a note becomes wrong, correct it in place and add a dated line under a
  `## Revisions` section. Don't leave stale claims standing.
- When you update a note, mention briefly in your response which note you
  updated, so the user can confirm.

### Docs vs notes

`lorekeeper-docs/<repo>/` is for documents you'd hand to a new teammate:
`overview.md`, `architecture.md`, `runbook.md`, `conventions.md`. Update in
place; don't create dated variants. Notes are scratch memory; docs are
polished reference.

### Mechanics

- A `SessionEnd` hook autonomously classifies finished sessions and writes a
  note if the session produced something non-obvious. Heuristic gate →
  Haiku classifier → Sonnet drafter. Disable per-user with
  `touch __LOREKEEPER_HOME__/.autonote-off` or `LOREKEEPER_AUTONOTE=off`.
- You do not need to run `qmd update` or `qmd embed` after writing — a
  PostToolUse hook handles that automatically.
- The first write into `notes/<repo>/` or `docs/<repo>/` auto-registers
  generic qmd contexts for that repo. Once several notes exist, the user
  may replace the description with a real blurb via
  `qmd context add qmd://lorekeeper-notes/<repo> "<summary>"`.
- If the user says "don't write notes" for a session, respect that and skip
  any explicit write request.

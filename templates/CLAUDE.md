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

### Write policy — when to create a note

Create or update a note in `lorekeeper-notes` when any of these are true:

- A debugging dead-end cost more than ~15 minutes and the answer wasn't obvious.
- A library, API, or internal system behaved non-obviously and you had to dig.
- An architectural or design decision was made — record the decision *and the
  reasoning*, not just the outcome.
- A configuration, env variable, or secret lives in a non-obvious location.
- The team follows a convention that isn't written down elsewhere in the repo.
- A recurring incident pattern has a known fix worth remembering.

Do NOT create a note for:

- Session summaries ("today we fixed X"). Memory ≠ journal.
- Things already in the repo's README, CONTRIBUTING, inline comments, or
  docstrings. If it's already documented, link to the file, don't restate it.
- Trivia that's faster to re-derive than to retrieve.

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

- You do not need to run `qmd update` or `qmd embed` after writing — a
  PostToolUse hook handles that automatically.
- The first write into `notes/<repo>/` or `docs/<repo>/` also auto-registers
  generic qmd contexts for that repo (description: `"Memory for repo '<repo>'"`).
  Once you've written ~3+ notes and have a clearer picture of what's in there,
  replace the generic description by running this via the Bash tool:
  ```
  qmd context add qmd://lorekeeper-notes/<repo> "<one-line summary of what the notes actually cover>"
  ```
  `qmd context add` overwrites. Do the same for `lorekeeper-docs/<repo>` if
  durable docs exist. Skip this on repos with sparse or generic notes.
- If the user explicitly says "don't write notes" for a session, respect that
  and skip the write policy entirely for that conversation.

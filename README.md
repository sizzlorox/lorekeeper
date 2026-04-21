# lorekeeper

Autonomous per-repo memory for Claude Code, backed by [qmd](https://github.com/tobi/qmd) for local semantic search and [caveman](https://github.com/JuliusBrussee/caveman) for token-efficient prose. Claude reads existing notes at session start, writes new ones when it learns something worth remembering, and re-indexes automatically — you never have to manage it by hand.

```
$XDG_DATA_HOME/lorekeeper/
├── notes/<repo>/    # session-to-session memory: gotchas, decisions, conventions
└── docs/<repo>/     # durable reference docs: overview, architecture, runbook
```

## What it does

- **Reads automatically.** A `SessionStart` hook injects an index of existing notes/docs for the current repo so Claude knows what memory is available. Claude uses qmd's MCP tools to fetch the specific files the task needs.
- **Writes selectively.** A strict policy in `CLAUDE.md` tells Claude *when* to create notes (non-obvious behavior, debugging dead-ends, design decisions) and *when not to* (session summaries, re-documentable trivia). Without this, notes collapse into noise within weeks.
- **Re-indexes itself.** A `PostToolUse` hook runs `qmd update && qmd embed` in the background whenever Claude writes under the notes/docs tree.
- **Uses caveman if present.** Ships a caveman-compressed `CLAUDE.md` block to cut input tokens on every session, and instructs Claude to write notes in caveman-speak so retrieval is cheap too.

## Requirements

- Claude Code CLI (≥ 2.1)
- Node.js ≥ 22
- `jq` (for settings.json merging)
- `git`
- Optional: [caveman](https://github.com/JuliusBrussee/caveman) plugin for token reduction

qmd is installed by the installer if missing.

## Install

```bash
git clone https://github.com/<you>/lorekeeper ~/.local/share/lorekeeper
~/.local/share/lorekeeper/install.sh
```

The installer is idempotent — re-run it after pulling updates.

Optional flags:

```bash
./install.sh --with-caveman         # also install caveman plugin
./install.sh --lorekeeper-home PATH # override data dir (default: $XDG_DATA_HOME/lorekeeper)
./install.sh --no-embed-bootstrap   # skip initial qmd embed (faster install, do it later)
```

## After install

Start a Claude Code session in any git repo. The first time you use a repo, Claude sees an empty index and is told to write notes when it learns something. After a few sessions you'll have organic coverage; seed it manually for repos you care about:

```bash
# Create a starter note
lorekeeper note <repo-name> architecture
# Opens $EDITOR on $LOREKEEPER_HOME/notes/<repo-name>/architecture.md
```

Verify everything is wired:

```bash
lorekeeper status
# qmd: installed
# collections: lorekeeper-notes (0 docs), lorekeeper-docs (0 docs)
# hooks: SessionStart ✓  PostToolUse ✓  UserPromptSubmit ✓
# caveman: detected (compressed CLAUDE.md in use)
```

## CLI

```
lorekeeper status              Check install health
lorekeeper add-repo <name>     Create notes/ and docs/ dirs, register contexts in qmd
lorekeeper note <repo> <slug>  Open $EDITOR on a note (creates from template if missing)
lorekeeper doc <repo> <slug>   Same for docs/
lorekeeper reindex             Force qmd update + embed
lorekeeper ls [repo]           List notes/docs per repo
```

## How caveman fits

Caveman is two separate things with different trade-offs:

1. **Caveman skill (output).** With the caveman plugin active, Claude's conversational output is caveman-style. The notes Claude writes under `$LOREKEEPER_HOME/notes/` are produced in that same compressed form — so when a future session retrieves them via qmd, the input-token cost of the note is already low. This is the biggest compounding win.

2. **Caveman-compress (input).** The global `CLAUDE.md` block that lorekeeper installs is pre-compressed (see `templates/CLAUDE.caveman.md`). It loads on every session; compression here saves tokens every time. Installer picks the compressed version when `--with-caveman` is passed or caveman is already installed.

If you don't want caveman, pass `--no-caveman` and the installer uses the uncompressed policy.

## Uninstall

```bash
~/.local/share/lorekeeper/uninstall.sh
```

Removes the hooks, the CLAUDE.md block, and the qmd collections. Your actual notes/docs are left in place — delete `$LOREKEEPER_HOME` by hand if you want them gone.

## How the pieces wire together

```
Claude Code session starts
    │
    ▼
SessionStart hook ─► reads git toplevel ─► ls $LOREKEEPER_HOME/{notes,docs}/<repo>
    │                                          │
    │                                          ▼
    │                           injects index as context → Claude sees what memory exists
    │
    ▼
Claude works, uses qmd MCP tools (query/get) to read specific notes
    │
    ▼
Claude writes a new note with Write tool → PostToolUse hook fires
    │
    ▼
Hook matches path under $LOREKEEPER_HOME → backgrounds `qmd update && qmd embed`
    │
    ▼
Next session: new note is searchable via MCP immediately
```

## License

MIT. See [LICENSE](LICENSE).

## Credits

- [tobi/qmd](https://github.com/tobi/qmd) — local hybrid search engine that does the actual retrieval
- [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman) — token compression for agents

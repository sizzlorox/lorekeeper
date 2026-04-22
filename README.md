# lorekeeper

Autonomous per-repo memory for Claude Code, backed by [qmd](https://github.com/tobi/qmd) for local semantic search and [caveman](https://github.com/JuliusBrussee/caveman) for token-efficient prose. Claude reads existing notes at session start, writes new ones when it learns something worth remembering, and re-indexes automatically — you never have to manage it by hand.

```
$XDG_DATA_HOME/lorekeeper/
├── notes/<repo>/    # session-to-session memory: gotchas, decisions, conventions
└── docs/<repo>/     # durable reference docs: overview, architecture, runbook
```

## What it does

- **Reads automatically.** A `SessionStart` hook injects an index of existing notes/docs for the current repo so Claude knows what memory is available. Claude uses qmd's MCP tools to fetch the specific files the task needs. When the repo has no prior memory, the hook stays silent — no mid-session prompting.
- **Writes autonomously.** A `SessionEnd` hook runs a two-stage classifier over the finished transcript: a cheap structural gate (tool-call count, error/decision keywords), then a Haiku yes/no on note-worthiness, then a Sonnet drafter that writes the note. No mid-session hinting to Claude, no decision to make inline. Disable with `touch $LOREKEEPER_HOME/.autonote-off` or `LOREKEEPER_AUTONOTE=off`.
- **Re-indexes itself.** A `PostToolUse` hook runs `qmd update && qmd embed` in the background whenever Claude writes under the notes/docs tree. The autonote hook triggers the same reindex directly after it writes.
- **Uses caveman if present.** Ships a caveman-compressed `CLAUDE.md` block to cut input tokens on every session, and instructs Claude to write notes in caveman-speak so retrieval is cheap too.

## Requirements

**All platforms**

- Claude Code CLI (≥ 2.1)
- Node.js ≥ 22
- `git`
- Optional: [caveman](https://github.com/JuliusBrussee/caveman) plugin for token reduction

**Linux/macOS only**

- `jq` (for `settings.json` merging in the bash installer)

qmd is installed by the installer if missing.

## Install

### Linux / macOS

```bash
git clone https://github.com/<you>/lorekeeper ~/.local/share/lorekeeper
~/.local/share/lorekeeper/install.sh
```

Optional flags:

```bash
./install.sh --with-caveman         # also install caveman plugin
./install.sh --lorekeeper-home PATH # override data dir (default: $XDG_DATA_HOME/lorekeeper)
./install.sh --no-embed-bootstrap   # skip initial qmd embed (faster install, do it later)
```

### Windows

Use the native PowerShell installer — no bash, no `jq` needed. Works in PowerShell 5.1 (built into Windows) or PowerShell 7+.

**Extra prerequisite:** [Git for Windows](https://git-scm.com/download/win). `qmd` ships its npm entrypoint as a POSIX shell script, so it needs `sh.exe` — Git for Windows provides one at `C:\Program Files\Git\bin\sh.exe`. The installer locates it automatically (or honors `$env:LOREKEEPER_SH`) and rewrites qmd's broken npm shims (`qmd.ps1` / `qmd.cmd`) to call it directly. If you re-install qmd via `npm` later, re-run `install.ps1` to repatch the shims.

```powershell
git clone https://github.com/<you>/lorekeeper "$env:LOCALAPPDATA\lorekeeper"
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\lorekeeper\install.ps1"
```

Flags mirror the bash installer:

```powershell
.\install.ps1 -WithCaveman
.\install.ps1 -LorekeeperHome C:\path\to\data
.\install.ps1 -NoEmbedBootstrap
```

Defaults on Windows:

| item              | path                                           |
| ----------------- | ---------------------------------------------- |
| data home         | `%LOCALAPPDATA%\lorekeeper`                    |
| claude config     | `%USERPROFILE%\.claude`                        |
| CLI (`lorekeeper.cmd`) | `%LOCALAPPDATA%\lorekeeper\bin`           |
| hook scripts      | `%USERPROFILE%\.claude\hooks\lorekeeper-*.ps1` |

The CLI directory is added to your user PATH automatically; open a new PowerShell window so the update takes effect. `uninstall.ps1` strips it back out. Running `install.sh` from Git Bash/MSYS aborts and points you at `install.ps1`.

The installer is idempotent on either platform — re-run after pulling updates.

## After install

Start a Claude Code session in any git repo. Work normally — nothing prompts Claude to take notes mid-session. When the session ends, the autonote hook scores the transcript and writes a note only if something non-obvious came up (debug dead-end, surprising library behavior, architectural decision, config in an odd place). After a few sessions you'll have organic coverage; seed it manually for repos you care about:

```bash
# Create a starter note
lorekeeper note <repo-name> architecture
# Opens $EDITOR on $LOREKEEPER_HOME/notes/<repo-name>/architecture.md
```

Verify everything is wired:

```bash
lorekeeper status
# qmd: installed
# collections: lorekeeper-notes, lorekeeper-docs
# hooks: lorekeeper-prime ✓  lorekeeper-reindex ✓  lorekeeper-autonote ✓
# autonote: enabled
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

Linux/macOS:

```bash
~/.local/share/lorekeeper/uninstall.sh
```

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\lorekeeper\uninstall.ps1"
```

Removes the hooks, the CLAUDE.md block, and the qmd collections. Your actual notes/docs are left in place — delete `$LOREKEEPER_HOME` (Linux/macOS) or `%LOCALAPPDATA%\lorekeeper` (Windows) by hand if you want them gone.

## How the pieces wire together

```
Claude Code session starts
    │
    ▼
SessionStart hook ─► reads git toplevel ─► ls $LOREKEEPER_HOME/{notes,docs}/<repo>
    │                                          │
    │                                          ▼
    │               if memory exists: injects index → Claude queries via qmd MCP
    │               if empty:         stays silent  → no hint, no noise
    ▼
Claude works normally
    │
    ▼
Session ends → SessionEnd hook fires (detached)
    │
    ├─► structural gate  (≥10 tool calls AND error/decision/surprise keywords?)
    │       │ no → skip
    │       ▼ yes
    ├─► Haiku classifier  ("is this session note-worthy? yes/no")
    │       │ no → skip
    │       ▼ yes
    └─► Sonnet drafter    → writes $LOREKEEPER_HOME/notes/<repo>/<slug>.md
                          → runs `qmd update && qmd embed`
                          → logs to $LOREKEEPER_HOME/.autonote.log

Next session: the new note is searchable via MCP immediately.
```

### Turning autonote off

- Per-install: `touch $LOREKEEPER_HOME/.autonote-off`  (Windows: create `%LOCALAPPDATA%\lorekeeper\.autonote-off`)
- Per-session: `export LOREKEEPER_AUTONOTE=off` before launching `claude`

## License

MIT. See [LICENSE](LICENSE).

## Credits

- [tobi/qmd](https://github.com/tobi/qmd) — local hybrid search engine that does the actual retrieval
- [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman) — token compression for agents

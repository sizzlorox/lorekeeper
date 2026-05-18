# @lorekeeper/omp-plugin

lorekeeper bindings for [oh-my-pi](https://github.com/can1357/oh-my-pi).

Routes omp's hook lifecycle into the same canonical `prime` / `reindex` /
`autonote` scripts that the Claude Code install uses, so a single
lorekeeper install serves both harnesses.

## Event mapping

| omp event           | action                                               |
| ------------------- | ---------------------------------------------------- |
| `session_start`     | spawn `hooks/prime.{ps1,sh}` with `{cwd, session_id}` |
| `turn_end`          | append the turn (user/assistant + tool results) to a synthetic JSONL transcript |
| `tool_result`       | on `write`/`edit`/`multiedit`/`ast_edit`/`apply_patch` success inside `$LOREKEEPER_HOME` → spawn `hooks/reindex` |
| `session_shutdown`  | spawn `hooks/autonote` with the synthetic transcript |

The synthetic transcript lives at
`$LOREKEEPER_HOME/transcripts/<session-id>.jsonl` and mimics Claude Code's
session log shape (`{type, message: {content: [...]}}` per line) so
`autonote` runs without modification.

## Install

The top-level `install.{ps1,sh}` does this automatically when `omp` and
`bun` are both on `PATH`. To install just the omp side:

```sh
./install.sh --no-claude        # Linux / macOS
.\install.ps1 -NoClaude          # Windows
```

To install manually after `omp` shows up on a machine that already has
lorekeeper:

```sh
cd <lorekeeper-checkout>/omp-plugin
bun install && bun run build
mkdir -p ~/.omp/plugins/node_modules/@lorekeeper
ln -s "$PWD" ~/.omp/plugins/node_modules/@lorekeeper/omp-plugin
echo "$HOME/.local/share/lorekeeper" > ~/.omp/.lorekeeper-home
```

Verify with `lorekeeper status` (look under the `omp:` section).

## Build (development)

```sh
cd omp-plugin
bun install
bun run build      # tsc -p tsconfig.json
```

## Architecture notes

- **Types come from real omp.** `src/index.ts` imports `ExtensionAPI`,
  `ExtensionContext`, `TurnEndEvent`, `ToolResultEvent`, `SessionStartEvent`,
  and `SessionShutdownEvent` from
  `@oh-my-pi/pi-coding-agent/extensibility/extensions`.
  `AgentMessage` + content part types come from `@oh-my-pi/pi-ai` and
  `@oh-my-pi/pi-agent-core`. No structural shim.
- **Session id** is read from `ctx.sessionManager.getSessionId()`. The
  event payloads do not carry it.
- **Dispatch** is `node:child_process.spawn` with stdin piped — omp's
  built-in `pi.exec` doesn't expose a stdin channel and the canonical
  hook scripts key off `cat | jq`.
- **Reindex / autonote run detached.** The plugin returns immediately;
  the spawned PowerShell/bash worker is what calls `qmd update && qmd embed`
  or the Haiku/Sonnet classifier.

## Coexistence with omp's Hindsight

omp ships a built-in memory system (Hindsight). lorekeeper's value on top
is qmd-backed durable docs, ADRs, and the `distill` pass. The plugin
doesn't touch Hindsight; both run independently.

## Known limitations

- The autonote classifier shells out to `claude -p` for Haiku/Sonnet
  calls. On an omp-only machine without the Claude CLI, autonote will
  no-op (silent). If you want autonote on omp-only setups, install the
  Claude CLI or disable autonote with `touch $LOREKEEPER_HOME/.autonote-off`.
- The plugin tracks one transcript per session id and writes the file on
  every `turn_end`. Synchronous append is fine for typical sessions; if
  you push thousands of turns through a single session, consider a
  buffered writer.

import * as path from "node:path";
import * as fs from "node:fs";
import type {
  ExtensionAPI,
  ExtensionContext,
  SessionStartEvent,
  SessionShutdownEvent,
  SessionCompactingEvent,
  SessionCompactEvent,
  TurnEndEvent,
  ToolResultEvent,
} from "@oh-my-pi/pi-coding-agent/extensibility/extensions";
import { runHook } from "./dispatch.js";
import { TranscriptWriter } from "./transcript.js";
import { resolveLorekeeperHome } from "./paths.js";
import { resolveRepo } from "./resolve.js";

const HANDOFF_RULES: readonly string[] = [
  "When summarizing this session for compaction, follow these rules:",
  "1. Preserve the WHY behind every decision — not just what was done, but why that approach was chosen and what alternatives were rejected.",
  "2. Keep exact file paths and line numbers that were read or modified.",
  "3. Keep error messages and stack traces verbatim when they informed a diagnosis or fix.",
  "4. State current task status: what is complete, what is in progress, what is blocked and by what.",
  "5. If this context already contains a previous compaction summary, carry its key points forward — do not discard prior history.",
  "6. Preserve any blockers and dependencies between tasks.",
];


/**
 * lorekeeper bindings for omp's extension runtime.
 *
 * Routes omp's hook lifecycle into the existing prime / reindex / autonote
 * scripts that the Claude Code install uses. The scripts read a Claude-Code-
 * shaped JSON envelope from stdin; we forge that shape per event so they run
 * unmodified — one set of scripts, two harnesses.
 *
 *   omp event           lorekeeper action
 *   ----------------------------------------------------------------------
 *   session_start    →  spawn hooks/prime   (cwd, session_id, hook_event_name)
 *   turn_end         →  append turn into synthetic JSONL transcript
 *   tool_result      →  on success + write/edit inside $LOREKEEPER_HOME →
 *                       spawn hooks/reindex (tool_input.file_path)
 *   session_shutdown →  spawn hooks/autonote (transcript_path → synthetic JSONL)
 */
export default function lorekeeperPlugin(pi: ExtensionAPI): void {
  // One transcript writer per session id. The agent process may host
  // multiple sessions (handoffs, branches, RPC mode), so we don't use a
  // module-level singleton.
  const transcripts = new Map<string, TranscriptWriter>();

  const transcriptFor = (sessionId: string): TranscriptWriter => {
    let w = transcripts.get(sessionId);
    if (!w) {
      w = new TranscriptWriter(sessionId);
      transcripts.set(sessionId, w);
    }
    return w;
  };

  const sessionIdOf = (ctx: ExtensionContext): string => {
    try {
      return ctx.sessionManager.getSessionId();
    } catch {
      return "";
    }
  };

  pi.on("session_start", async (_event: SessionStartEvent, ctx: ExtensionContext) => {
    const sessionId = sessionIdOf(ctx);
    try {
      await runHook("prime", {
        cwd: ctx.cwd,
        stdinJson: {
          cwd: ctx.cwd,
          session_id: sessionId,
          hook_event_name: "SessionStart",
        },
      });
    } catch (err) {
      pi.logger.debug("lorekeeper: prime hook failed", { err: String(err) });
    }
  });

  pi.on("turn_end", (event: TurnEndEvent, ctx: ExtensionContext) => {
    const sessionId = sessionIdOf(ctx);
    if (!sessionId) return;
    const writer = transcriptFor(sessionId);
    writer.appendAgentMessage(event.message);
    for (const result of event.toolResults) writer.appendAgentMessage(result);
  });

  pi.on("tool_result", async (event: ToolResultEvent, ctx: ExtensionContext) => {
    if (event.isError) return;
    if (!isWriteLikeTool(event.toolName)) return;

    const filePath = extractWrittenPath(event.input);
    if (!filePath) return;

    // Filter to writes inside $LOREKEEPER_HOME before paying for a spawn.
    // The reindex script also gates on this; doing it here keeps the agent
    // loop quiet on every unrelated edit.
    const home = resolveLorekeeperHome();
    if (!isInsideHome(filePath, home)) return;

    try {
      await runHook("reindex", {
        cwd: ctx.cwd,
        fireAndForget: true,
        stdinJson: { tool_input: { file_path: filePath } },
      });
    } catch (err) {
      pi.logger.debug("lorekeeper: reindex hook failed", { err: String(err) });
    }
  });

  pi.on("session_shutdown", async (_event: SessionShutdownEvent, ctx: ExtensionContext) => {
    const sessionId = sessionIdOf(ctx);
    if (!sessionId) return;

    const writer = transcripts.get(sessionId);
    transcripts.delete(sessionId);
    if (!writer) return; // nothing to classify — bail before spawning claude

    try {
      await runHook("autonote", {
        cwd: ctx.cwd,
        fireAndForget: true,
        stdinJson: {
          transcript_path: writer.path,
          cwd: ctx.cwd,
          session_id: sessionId,
        },
      });
    } catch (err) {
      pi.logger.debug("lorekeeper: autonote hook failed", { err: String(err) });
    }
  });

  pi.on("session.compacting", async (_event: SessionCompactingEvent, ctx: ExtensionContext) => {
    // Best-effort: inject relevant lorekeeper notes into the compaction summary.
    // This ensures the compacted context preserves awareness of prior learnings.
    const home = resolveLorekeeperHome();
    const cwd = ctx.cwd;
    // Worktree-/submodule-aware key: worktrees share one memory, submodules
    // keep their own. Mirror of hooks/lib/resolve.sh.
    const ident = resolveRepo(cwd);
    if (!ident.toplevel) return; // not a git repo
    const repo = ident.key;
    if (!repo) return;

    const notesDir = path.join(home, "notes", repo);
    const docsDir = path.join(home, "docs", repo);

    const contextLines: string[] = [
      "== LOREKEEPER: HANDOFF CONTEXT ==",
      "",
      ...HANDOFF_RULES,
      "",
    ];

    // Collect note/doc content from disk, capped at 10 files total.
    const noteEntries: { label: string; name: string; content: string }[] = [];

    for (const [dir, label] of [[notesDir, "note"], [docsDir, "doc"]] as const) {
      try {
        const entries = fs.readdirSync(dir).filter(f => f.endsWith(".md"));
        for (const entry of entries) {
          if (noteEntries.length >= 10) break;
          try {
            const raw = fs.readFileSync(path.join(dir, entry), "utf8");
            noteEntries.push({
              label,
              name: entry.replace(/\.md$/, ""),
              content: raw.length > 1500 ? raw.slice(0, 1500) : raw,
            });
          } catch { /* skip unreadable files */ }
        }
      } catch { /* dir doesn't exist */ }
    }

    if (noteEntries.length > 0) {
      contextLines.push(
        "The following notes from previous sessions may provide relevant context.",
        "Preserve any insights that are relevant to the current work:",
        "",
      );
      for (const entry of noteEntries) {
        contextLines.push(
          `### lorekeeper ${entry.label}: ${entry.name}`,
          entry.content,
          "",
        );
      }
    }

    return {
      context: contextLines,
    };
  });

  pi.on("session_compact", async (event: SessionCompactEvent, ctx: ExtensionContext) => {
    const sessionId = sessionIdOf(ctx);
    if (!sessionId) return;

    const writer = transcripts.get(sessionId);
    if (!writer) return;

    // Save watermark so SessionEnd's autonote skips already-processed lines.
    const home = resolveLorekeeperHome();
    const watermarkDir = path.join(home, ".compact-watermark");
    try {
      fs.mkdirSync(watermarkDir, { recursive: true });
      fs.writeFileSync(path.join(watermarkDir, sessionId), String(writer.lineCount), "utf8");
    } catch {
      // best-effort
    }

    try {
      await runHook("compact", {
        cwd: ctx.cwd,
        fireAndForget: true,
        stdinJson: {
          transcript_path: writer.path,
          cwd: ctx.cwd,
          session_id: sessionId,
          hook_event_name: "PostCompact",
          trigger: event.fromExtension ? "manual" : "auto",
          compact_summary: event.compactionEntry.summary,
        },
      });
    } catch (err) {
      pi.logger.debug("lorekeeper: compact hook failed", { err: String(err) });
    }
  });
}

function isWriteLikeTool(name: string): boolean {
  // Match against the omp tool ids that produce or modify files. `ast_edit`
  // is the codemod tool; `apply_patch` is the patch tool. New tools that
  // create files should be added here.
  switch (name.toLowerCase()) {
    case "write":
    case "edit":
    case "multiedit":
    case "ast_edit":
    case "apply_patch":
      return true;
    default:
      return false;
  }
}

function extractWrittenPath(input: Record<string, unknown>): string | null {
  const raw = (input.file_path ?? input.path ?? input.target ?? input.filePath) as unknown;
  return typeof raw === "string" && raw.length > 0 ? raw : null;
}

function isInsideHome(filePath: string, home: string): boolean {
  const abs = path.isAbsolute(filePath) ? filePath : path.resolve(filePath);
  const a = abs.replace(/[\\/]+$/, "").toLowerCase();
  const h = home.replace(/[\\/]+$/, "").toLowerCase();
  if (a === h) return true;
  return a.startsWith(`${h}\\`) || a.startsWith(`${h}/`);
}

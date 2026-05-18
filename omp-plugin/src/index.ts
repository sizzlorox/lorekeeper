import * as path from "node:path";
import type {
  ExtensionAPI,
  ExtensionContext,
  SessionStartEvent,
  SessionShutdownEvent,
  TurnEndEvent,
  ToolResultEvent,
} from "@oh-my-pi/pi-coding-agent/extensibility/extensions";
import { runHook } from "./dispatch.js";
import { TranscriptWriter } from "./transcript.js";
import { resolveLorekeeperHome } from "./paths.js";

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

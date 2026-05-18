import { spawn } from "node:child_process";
import * as fs from "node:fs";
import { resolveHookScript, resolveLorekeeperHome, type ScriptRef } from "./paths.js";

interface RunOpts {
  readonly cwd?: string;
  readonly stdinJson: unknown;
  /**
   * Fire-and-forget: spawn the script, write stdin, return immediately
   * without awaiting the child. The script is expected to daemonize its
   * own long-running work (reindex / autonote both `Start-Process` a hidden
   * worker before exiting). The parent process keeps running while the
   * child does its thing.
   *
   * We **do not** use Node's `detached: true` here. On Windows, `detached`
   * combined with a stdin pipe loses the pipe (the child gets a console
   * session disconnected from the parent's stdin), so the script reads
   * nothing. We instead pipe normally and just don't `await` the close
   * event — the child stays alive even after the parent returns.
   */
  readonly fireAndForget?: boolean;
  readonly extraEnv?: Record<string, string>;
}

function commandFor(script: ScriptRef): { cmd: string; args: string[] } {
  if (script.interpreter === "powershell") {
    return {
      cmd: "powershell",
      args: ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script.path],
    };
  }
  return { cmd: "bash", args: [script.path] };
}

/**
 * Spawn one of the lorekeeper hook scripts (prime / reindex / autonote) with
 * a Claude-Code-shaped JSON payload on stdin. The scripts read stdin and key
 * off fields like `cwd`, `session_id`, `hook_event_name`,
 * `tool_input.file_path`, and `transcript_path`. We forge that shape so the
 * scripts run unmodified.
 *
 * `LOREKEEPER_HOME` is exported via env so the scripts pick up the right
 * home even when invoked from omp (which doesn't drop a marker into
 * `~/.claude`).
 */
export async function runHook(
  name: "prime" | "reindex" | "autonote",
  opts: RunOpts
): Promise<void> {
  const script = resolveHookScript(name);
  if (!fs.existsSync(script.path)) {
    // Scripts ship with the lorekeeper install. If they're missing the user
    // hasn't installed lorekeeper for this machine yet — bail silently rather
    // than spam the agent's stderr on every event.
    return;
  }

  const { cmd, args } = commandFor(script);
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    LOREKEEPER_HOME: resolveLorekeeperHome(),
    ...opts.extraEnv,
  };

  const child = spawn(cmd, args, {
    cwd: opts.cwd ?? process.cwd(),
    env,
    // ignore the child's stdout/stderr — the hook scripts already log to
    // $LOREKEEPER_HOME/.autonote.log and friends. We only care about stdin.
    stdio: ["pipe", "ignore", "ignore"],
    windowsHide: true,
  });

  // Capture errors quietly — the agent loop shouldn't crash on a missing
  // interpreter or a permission error in the hook chain.
  const closed = new Promise<void>((resolve) => {
    child.once("error", () => resolve());
    child.once("close", () => resolve());
  });

  try {
    child.stdin?.write(JSON.stringify(opts.stdinJson ?? {}));
    child.stdin?.end();
  } catch {
    /* stdin closed early — scripts handle empty input */
  }

  // Fire-and-forget callers (reindex / autonote) return immediately.
  // The child stays alive and finishes its background daemon work.
  if (opts.fireAndForget) {
    // Drop the unhandled rejection guard rail: we still consume the close
    // promise so it doesn't leak as an unhandled error.
    closed.catch(() => {});
    return;
  }

  await closed;
}

import * as os from "node:os";
import * as path from "node:path";
import * as fs from "node:fs";

const isWin = process.platform === "win32";

/**
 * Resolve $LOREKEEPER_HOME the same way the existing shell/PowerShell hooks do:
 *   1. $LOREKEEPER_HOME from env (preferred — set by this plugin when spawning scripts)
 *   2. marker file under ~/.omp/.lorekeeper-home (omp-side install)
 *   3. marker file under ~/.claude/.lorekeeper-home (legacy Claude Code install on the same machine)
 *   4. platform default
 */
export function resolveLorekeeperHome(): string {
  const fromEnv = process.env.LOREKEEPER_HOME?.trim();
  if (fromEnv) return fromEnv;

  const home = os.homedir();
  const candidates = [
    process.env.OMP_CONFIG_DIR ? path.join(process.env.OMP_CONFIG_DIR, ".lorekeeper-home") : null,
    path.join(home, ".omp", ".lorekeeper-home"),
    process.env.CLAUDE_CONFIG_DIR ? path.join(process.env.CLAUDE_CONFIG_DIR, ".lorekeeper-home") : null,
    path.join(home, ".claude", ".lorekeeper-home"),
  ].filter((p): p is string => !!p);

  for (const marker of candidates) {
    try {
      const v = fs.readFileSync(marker, "utf8").trim();
      if (v) return v;
    } catch {
      /* not present */
    }
  }

  return isWin
    ? path.join(process.env.LOCALAPPDATA ?? path.join(home, "AppData", "Local"), "lorekeeper")
    : path.join(process.env.XDG_DATA_HOME ?? path.join(home, ".local", "share"), "lorekeeper");
}

export interface ScriptRef {
  readonly interpreter: "powershell" | "bash";
  readonly path: string;
}

export function resolveHookScript(name: "prime" | "reindex" | "autonote"): ScriptRef {
  const home = resolveLorekeeperHome();
  if (isWin) {
    return { interpreter: "powershell", path: path.join(home, "hooks", `${name}.ps1`) };
  }
  return { interpreter: "bash", path: path.join(home, "hooks", `${name}.sh`) };
}

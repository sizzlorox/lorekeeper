import { execFileSync } from "node:child_process";
import * as path from "node:path";
import * as fs from "node:fs";

/**
 * lorekeeper repo-identity resolver (TypeScript) — mirror of hooks/lib/resolve.sh
 * and resolve.ps1. See resolve.sh for the full contract.
 *
 *   key         memory key -> notes/<key>/, docs/<key>/
 *   toplevel    git rev-parse --show-toplevel (the checkout you're in)
 *   main        path of the MAIN worktree for this repo
 *   isWorktree  true in a linked worktree, false in a main checkout, undefined if non-git
 *   parentKey   key of the superproject if this is a submodule, else undefined
 *   subPath     submodule path relative to the superproject, else undefined
 *
 * Non-git dir: key = basename(cwd), everything else undefined. Avoids
 * --path-format (needs git 2.31); requires git >= 2.13.
 */
export interface RepoIdentity {
  key: string;
  toplevel?: string;
  main?: string;
  isWorktree?: boolean;
  parentKey?: string;
  subPath?: string;
}

function git(dir: string, args: string[]): string {
  try {
    return execFileSync("git", ["-C", dir, ...args], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return "";
  }
}

/** Memory key for `dir` (basename if non-git). Self-contained for superproject recursion. */
export function repoKey(dir: string): string {
  const top = git(dir, ["rev-parse", "--show-toplevel"]);
  if (!top) return path.basename(path.resolve(dir));
  const ovr = git(dir, ["config", "--get", "lorekeeper.key"]);
  if (ovr) return ovr;
  const agd = git(dir, ["rev-parse", "--absolute-git-dir"]);
  if (agd && fs.existsSync(path.join(agd, "commondir"))) {
    // Linked worktree: first porcelain entry is the MAIN worktree.
    const lines = git(dir, ["worktree", "list", "--porcelain"]).split("\n");
    const main = (lines[0] ?? "").replace(/^worktree /, "");
    const second = lines[1] ?? "";
    const leaf = path.basename(main);
    if (second === "bare") {
      if (leaf === ".git" || leaf === ".bare") return path.basename(path.dirname(main));
      return leaf.replace(/\.git$/, "");
    }
    return leaf;
  }
  return path.basename(top);
}

export function resolveRepo(dir: string): RepoIdentity {
  const top = git(dir, ["rev-parse", "--show-toplevel"]);
  if (!top) return { key: path.basename(path.resolve(dir)) };

  const r: RepoIdentity = { key: repoKey(dir), toplevel: top };

  const agd = git(dir, ["rev-parse", "--absolute-git-dir"]);
  if (agd && fs.existsSync(path.join(agd, "commondir"))) {
    r.isWorktree = true;
    r.main = git(dir, ["worktree", "list", "--porcelain"]).split("\n")[0]?.replace(/^worktree /, "") || top;
  } else {
    r.isWorktree = false;
    r.main = top;
  }

  const sup = git(top, ["rev-parse", "--show-superproject-working-tree"]);
  if (sup) {
    r.parentKey = repoKey(sup);
    r.subPath = top.startsWith(sup + "/") ? top.slice(sup.length + 1) : top;
  }
  return r;
}

// Direct-exec mode (parity harness): print fields for <dir|.> as key=value lines.
// `import.meta.main` is true only when run as the entry script (bun/node >=22).
// @ts-ignore - import.meta.main is a bun/node runtime flag not in older libdts
if (import.meta.main) {
  const r = resolveRepo(process.argv[2] ?? ".");
  process.stdout.write(
    [
      `key=${r.key}`,
      `toplevel=${r.toplevel ?? ""}`,
      `main=${r.main ?? ""}`,
      `is_worktree=${r.isWorktree === undefined ? "" : r.isWorktree ? "1" : "0"}`,
      `parent_key=${r.parentKey ?? ""}`,
      `sub_path=${r.subPath ?? ""}`,
      "",
    ].join("\n"),
  );
}

# lorekeeper repo-identity resolver (PowerShell).
#
# ONE implementation shared by every .ps1 hook and bin/lorekeeper.ps1, mirroring
# resolve.sh / resolve.ts. Dot-source it, then call `Resolve-LkRepo -Dir $cwd`,
# which returns a PSCustomObject:
#
#   Key         memory key -> notes/<Key>/, docs/<Key>/
#   Toplevel    git rev-parse --show-toplevel (the checkout you're in)
#   Main        path of the MAIN worktree for this repo
#   IsWorktree  1 if in a linked worktree, 0 if main checkout, '' if non-git
#   ParentKey   key of the superproject if this is a submodule, else ''
#   SubPath     submodule path relative to the superproject, else ''
#
# Non-git dir: Key = leaf of cwd, everything else empty. Backward-compatible:
# for a main checkout Main == Toplevel, so leaf(Main) == today's leaf(Toplevel).
# Avoids --path-format (needs git 2.31); requires git >= 2.13.

function Get-LkGit {
  param([string]$Dir, [string[]]$GitArgs)
  # Function-scoped: a caller with $ErrorActionPreference='Stop' (e.g. the CLI) would
  # otherwise throw on git's stderr for a non-git dir (PowerShell 5.1 native-stderr).
  $ErrorActionPreference = 'SilentlyContinue'
  $out = & git -C $Dir @GitArgs 2>$null
  if ($LASTEXITCODE -ne 0) { return '' }
  if ($null -eq $out) { return '' }
  return ($out | Out-String).Trim()
}

function Get-LkKey {
  param([string]$Dir)
  $ErrorActionPreference = 'SilentlyContinue'   # tolerate git stderr under Stop callers
  $top = Get-LkGit $Dir @('rev-parse', '--show-toplevel')
  if (-not $top) { return (Split-Path -Leaf $Dir) }
  # Collision escape hatch; lives in common config, shared by all worktrees.
  $ovr = Get-LkGit $Dir @('config', '--get', 'lorekeeper.key')
  if ($ovr) { return $ovr }
  $agd = Get-LkGit $Dir @('rev-parse', '--absolute-git-dir')
  if ($agd -and (Test-Path -LiteralPath (Join-Path $agd 'commondir'))) {
    # Linked worktree: first porcelain entry is the MAIN worktree.
    $wl = & git -C $Dir worktree list --porcelain 2>$null
    $lines = @($wl)
    $main = ($lines | Select-Object -First 1) -replace '^worktree ', ''
    $second = if ($lines.Count -ge 2) { $lines[1] } else { '' }
    $leaf = Split-Path -Leaf $main
    if ($second -eq 'bare') {
      if ($leaf -eq '.git' -or $leaf -eq '.bare') {
        return (Split-Path -Leaf (Split-Path -Parent $main))
      }
      return ($leaf -replace '\.git$', '')
    }
    return $leaf
  }
  return (Split-Path -Leaf $top)
}

function Resolve-LkRepo {
  param([string]$Dir)
  $ErrorActionPreference = 'SilentlyContinue'   # tolerate git stderr under Stop callers
  $r = [pscustomobject]@{
    Key = ''; Toplevel = ''; Main = ''; IsWorktree = ''; ParentKey = ''; SubPath = ''
  }
  $top = Get-LkGit $Dir @('rev-parse', '--show-toplevel')
  if (-not $top) {
    $r.Key = Split-Path -Leaf $Dir
    return $r
  }
  $r.Toplevel = $top
  $r.Key = Get-LkKey $Dir
  $agd = Get-LkGit $Dir @('rev-parse', '--absolute-git-dir')
  if ($agd -and (Test-Path -LiteralPath (Join-Path $agd 'commondir'))) {
    $r.IsWorktree = '1'
    $wl = & git -C $Dir worktree list --porcelain 2>$null
    $r.Main = (@($wl) | Select-Object -First 1) -replace '^worktree ', ''
  } else {
    $r.IsWorktree = '0'
    $r.Main = $top
  }
  $super = Get-LkGit $top @('rev-parse', '--show-superproject-working-tree')
  if ($super) {
    $r.ParentKey = Get-LkKey $super
    $r.SubPath = $top
    if ($top.StartsWith("$super/")) { $r.SubPath = $top.Substring($super.Length + 1) }
  }
  return $r
}

# Direct-exec mode (parity harness): print fields for <dir|.> as key=value lines.
if ($MyInvocation.InvocationName -ne '.') {
  $d = if ($args.Count -ge 1) { $args[0] } else { '.' }
  $r = Resolve-LkRepo -Dir $d
  "key=$($r.Key)"
  "toplevel=$($r.Toplevel)"
  "main=$($r.Main)"
  "is_worktree=$($r.IsWorktree)"
  "parent_key=$($r.ParentKey)"
  "sub_path=$($r.SubPath)"
}

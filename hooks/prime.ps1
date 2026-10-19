#Requires -Version 5.1
# lorekeeper: SessionStart / UserPromptSubmit hook (Windows/PowerShell)
# Reads cwd from Claude Code's JSON input, resolves the repo name, and emits
# an index of existing notes/docs. stdout becomes additional context.

$ErrorActionPreference = 'SilentlyContinue'

$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$homeFile = Join-Path $ClaudeDir '.lorekeeper-home'
$LorekeeperHome = if ($env:LOREKEEPER_HOME) { $env:LOREKEEPER_HOME }
                  elseif (Test-Path $homeFile) { (Get-Content -Raw $homeFile).Trim() }
                  else { Join-Path $env:LOCALAPPDATA 'lorekeeper' }

$inputRaw = [Console]::In.ReadToEnd()
$data = $null
try { if ($inputRaw) { $data = $inputRaw | ConvertFrom-Json } } catch { $data = $null }

$cwd       = if ($data -and $data.cwd)             { [string]$data.cwd }             else { '' }
$sessionId = if ($data -and $data.session_id)      { [string]$data.session_id }      else { '' }
$evt       = if ($data -and $data.hook_event_name) { [string]$data.hook_event_name } else { '' }

# UserPromptSubmit: fire once per session
if ($evt -eq 'UserPromptSubmit' -and $sessionId) {
  $markerDir = Join-Path $env:TEMP 'lorekeeper'
  New-Item -ItemType Directory -Force -Path $markerDir | Out-Null
  $marker = Join-Path $markerDir "session-$sessionId"
  if (Test-Path $marker) { exit 0 }
  New-Item -ItemType File -Path $marker -Force | Out-Null
  Get-ChildItem $markerDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
    Remove-Item -Force -ErrorAction SilentlyContinue
}

# Resolve repo identity (worktree-/submodule-aware) via the shared resolver.
# Prefer the sibling lib (canonical hooks + repo), fall back to the installed copy.
$lkLib = Join-Path $PSScriptRoot 'lib\resolve.ps1'
if (-not (Test-Path $lkLib)) { $lkLib = Join-Path $LorekeeperHome 'hooks\lib\resolve.ps1' }
if (Test-Path $lkLib) { . $lkLib }

$lk = $null
if ($cwd -and (Test-Path $cwd) -and (Get-Command Resolve-LkRepo -ErrorAction SilentlyContinue)) {
  $lk = Resolve-LkRepo -Dir $cwd
}
$repo = if ($lk) { $lk.Key } else { '' }
if (-not $repo) { exit 0 }

$notesDir       = Join-Path $LorekeeperHome "notes\$repo"
$docsDir        = Join-Path $LorekeeperHome "docs\$repo"
$sharedNotesDir = Join-Path $LorekeeperHome 'notes\shared'

# Staleness cutoff: 90 days
$staleCutoff = (Get-Date).AddDays(-90).ToString('yyyy-MM-dd')

function Get-NoteDate([string]$FilePath) {
  $lines = Get-Content -LiteralPath $FilePath -TotalCount 20 -ErrorAction SilentlyContinue
  foreach ($ln in $lines) {
    if ($ln -match '^updated:\s*(.+)') { return $Matches[1].Trim() }
  }
  foreach ($ln in $lines) {
    if ($ln -match '^date:\s*(.+)')    { return $Matches[1].Trim() }
  }
  return ''
}

function Is-Stale([string]$FilePath) {
  $d = Get-NoteDate $FilePath
  return ($d -ne '' -and $d -lt $staleCutoff)
}

function Get-MdList {
  param([string]$Dir)
  if (-not (Test-Path $Dir)) { return @() }
  $root = (Resolve-Path $Dir).Path.TrimEnd('\')
  Get-ChildItem -Path $Dir -Recurse -Depth 3 -Filter *.md -File -ErrorAction SilentlyContinue |
    ForEach-Object {
      $rel = $_.FullName.Substring($root.Length + 1)
      $rel.Replace('\','/')
    } | Sort-Object
}

$notesFiles  = @(Get-MdList -Dir $notesDir)
$docsFiles   = @(Get-MdList -Dir $docsDir)
$sharedFiles = @(Get-MdList -Dir $sharedNotesDir)

# --- cross-boundary hints: one line each, no file listings (token-flat) ---
function Count-Md([string]$Dir) {
  if (-not (Test-Path $Dir)) { return 0 }
  @(Get-ChildItem -Path $Dir -Recurse -Filter *.md -File -ErrorAction SilentlyContinue).Count
}

$parentLine = ''
if ($lk.ParentKey) {
  $pn = Count-Md (Join-Path $LorekeeperHome "notes\$($lk.ParentKey)")
  $pd = Count-Md (Join-Path $LorekeeperHome "docs\$($lk.ParentKey)")
  if ($pn -ne 0 -or $pd -ne 0) {
    $parentLine = "parent '$($lk.ParentKey)': $pn notes, $pd docs — search it if the task crosses the boundary."
  }
}

$submodLine = ''
$gm = if ($lk.Toplevel) { Join-Path $lk.Toplevel '.gitmodules' } else { '' }
if (-not $lk.ParentKey -and $gm -and (Test-Path $gm)) {
  $acc = @(); $c = 0
  foreach ($line in @(& git -C $lk.Toplevel config --file $gm --get-regexp '\.path$' 2>$null)) {
    $sp = ($line -split '\s+', 2)[1]
    if (-not $sp) { continue }
    $sk = Split-Path -Leaf $sp
    $stot = (Count-Md (Join-Path $LorekeeperHome "notes\$sk")) + (Count-Md (Join-Path $LorekeeperHome "docs\$sk"))
    if ($stot -eq 0) { continue }
    $c++; if ($c -le 5) { $acc += "$sk ($stot)" }
  }
  if ($acc.Count -gt 0) { $submodLine = 'submodules with memory: ' + ($acc -join ', ') }
}

if ($notesFiles.Count -eq 0 -and $docsFiles.Count -eq 0 -and $sharedFiles.Count -eq 0) {
  # No own memory. Emit at most one cross-boundary hint, else stay silent.
  if ($parentLine) { Write-Output "## lorekeeper: $parentLine" }
  elseif ($submodLine) { Write-Output "## lorekeeper: $submodLine" }
  exit 0
}

$hdrSuffix = ''
if ($lk.ParentKey) { $hdrSuffix = " (submodule of '$($lk.ParentKey)')" }
elseif ($lk.IsWorktree -eq '1') { $hdrSuffix = ' (worktree)' }

Write-Output "## lorekeeper: repo '$repo'$hdrSuffix"
Write-Output ''
Write-Output 'Prior memory exists. Use `mcp__qmd__query` with collections=["lorekeeper-notes","lorekeeper-docs"]'
Write-Output 'to search semantically, or `mcp__qmd__get` to fetch a specific file by path.'
Write-Output "Pull only what the current task needs — don't bulk-load."
Write-Output ''
if ($parentLine) { Write-Output $parentLine; Write-Output '' }
if ($submodLine) { Write-Output $submodLine; Write-Output '' }

function Emit-Listing {
  param([string]$Kind, [string]$RepoName, [string[]]$Files, [string]$BaseDir)
  foreach ($f in $Files) {
    $staleMarker = ''
    $fullPath = Join-Path $BaseDir $f
    if ((Test-Path $fullPath) -and (Is-Stale $fullPath)) { $staleMarker = ' [STALE?]' }
    Write-Output "  $Kind/$RepoName/$f$staleMarker"
  }
}

if ($notesFiles.Count -gt 0) {
  Write-Output "### notes ($($notesFiles.Count) files):"
  Emit-Listing -Kind 'notes' -RepoName $repo -Files $notesFiles -BaseDir $notesDir
  Write-Output ''
}

if ($sharedFiles.Count -gt 0) {
  Write-Output "### shared notes ($($sharedFiles.Count) files — cross-repo):"
  Emit-Listing -Kind 'notes' -RepoName 'shared' -Files $sharedFiles -BaseDir $sharedNotesDir
  Write-Output ''
}

if ($docsFiles.Count -gt 0) {
  Write-Output "### docs ($($docsFiles.Count) files):"
  Emit-Listing -Kind 'docs' -RepoName $repo -Files $docsFiles -BaseDir $docsDir
  Write-Output ''
}

# Distill pending reminder.
$pendingFlag = Join-Path $LorekeeperHome "\.distill-pending\$repo"
if (Test-Path $pendingFlag) {
  Write-Output '> **lorekeeper:** distill pending for this repo — notes have grown significantly since'
  Write-Output '> last synthesis. Consider running `lorekeeper distill` when this session ends.'
  Write-Output ''
}

exit 0

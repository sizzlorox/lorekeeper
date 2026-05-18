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

# Resolve repo name
$repo = ''
if ($cwd -and (Test-Path $cwd)) {
  Push-Location $cwd
  try {
    $top = & git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $top) {
      $repo = Split-Path $top.Trim() -Leaf
    } else {
      $repo = Split-Path $cwd -Leaf
    }
  } finally { Pop-Location }
}

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

if ($notesFiles.Count -eq 0 -and $docsFiles.Count -eq 0 -and $sharedFiles.Count -eq 0) {
  # No memory yet — stay silent.
  exit 0
}

Write-Output "## lorekeeper: repo '$repo'"
Write-Output ''
Write-Output 'Prior memory exists. Use `mcp__qmd__query` with collections=["lorekeeper-notes","lorekeeper-docs"]'
Write-Output 'to search semantically, or `mcp__qmd__get` to fetch a specific file by path.'
Write-Output "Pull only what the current task needs — don't bulk-load."
Write-Output ''

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

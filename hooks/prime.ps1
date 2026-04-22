#Requires -Version 5.1
# lorekeeper: SessionStart / UserPromptSubmit hook (Windows/PowerShell)
# Reads cwd from Claude Code's JSON input, resolves the repo name, and emits
# an index of existing notes/docs. stdout becomes additional context.

$ErrorActionPreference = 'SilentlyContinue'

$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$homeFile = Join-Path $ClaudeDir '.lorekeeper-home'
$LorekeeperHome = if (Test-Path $homeFile) { (Get-Content -Raw $homeFile).Trim() } else { Join-Path $env:LOCALAPPDATA 'lorekeeper' }

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

$notesDir = Join-Path $LorekeeperHome "notes\$repo"
$docsDir  = Join-Path $LorekeeperHome "docs\$repo"

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

$notesFiles = @(Get-MdList -Dir $notesDir)
$docsFiles  = @(Get-MdList -Dir $docsDir)

if ($notesFiles.Count -eq 0 -and $docsFiles.Count -eq 0) {
  # No memory yet — stay silent. The SessionEnd autonote hook captures
  # learnings without prompting Claude mid-session.
  exit 0
}

Write-Output "## lorekeeper: repo '$repo'"
Write-Output ''
Write-Output 'Prior memory exists. Use `mcp__qmd__query` with collections=["lorekeeper-notes","lorekeeper-docs"]'
Write-Output 'to search semantically, or `mcp__qmd__get` to fetch a specific file by path.'
Write-Output "Pull only what the current task needs — don't bulk-load."
Write-Output ''

if ($notesFiles.Count -gt 0) {
  Write-Output "### notes ($($notesFiles.Count) files):"
  foreach ($f in $notesFiles) { Write-Output "  notes/$repo/$f" }
  Write-Output ''
}
if ($docsFiles.Count -gt 0) {
  Write-Output "### docs ($($docsFiles.Count) files):"
  foreach ($f in $docsFiles) { Write-Output "  docs/$repo/$f" }
  Write-Output ''
}

exit 0

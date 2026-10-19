#Requires -Version 5.1
# lorekeeper: PreCompact hook (Windows) — inject handoff context into compact prompt.
# stdout → appended to compact prompt. No LLM calls. Disk reads only.

$ErrorActionPreference = 'SilentlyContinue'

# Resolve LorekeeperHome (same logic as compact.ps1 / autonote.ps1)
$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$homeFile  = Join-Path $ClaudeDir '.lorekeeper-home'
$LorekeeperHome = if ($env:LOREKEEPER_HOME) { $env:LOREKEEPER_HOME }
                  elseif (Test-Path $homeFile) { (Get-Content -Raw $homeFile).Trim() }
                  else { Join-Path $env:LOCALAPPDATA 'lorekeeper' }

# Off switch
if (Test-Path (Join-Path $LorekeeperHome '.autonote-off')) { exit 0 }
if ($env:LOREKEEPER_AUTONOTE -eq 'off') { exit 0 }

# Read stdin, parse JSON
$inputRaw = [Console]::In.ReadToEnd()
$data = $null
try { if ($inputRaw) { $data = $inputRaw | ConvertFrom-Json } } catch { exit 0 }
if (-not $data) { exit 0 }

$cwd = [string]$data.cwd
if (-not $cwd -or -not (Test-Path $cwd)) { exit 0 }

# Resolve repo identity (worktree-/submodule-aware) via the shared resolver.
$lkLib = Join-Path $PSScriptRoot 'lib\resolve.ps1'
if (-not (Test-Path $lkLib)) { $lkLib = Join-Path $LorekeeperHome 'hooks\lib\resolve.ps1' }
if (Test-Path $lkLib) { . $lkLib }
if (-not (Get-Command Resolve-LkRepo -ErrorAction SilentlyContinue)) { exit 0 }
$lk = Resolve-LkRepo -Dir $cwd
if (-not $lk.Toplevel) { exit 0 }   # not a git repo
$repo = $lk.Key                     # worktrees share one key; submodules keep their own

# Collect note/doc files (most recently modified first, cap at 10)
$notesDir = Join-Path $LorekeeperHome "notes\$repo"
$docsDir  = Join-Path $LorekeeperHome "docs\$repo"

$files = @()
foreach ($dir in @($notesDir, $docsDir)) {
  if (Test-Path $dir) {
    $files += Get-ChildItem -Path $dir -Filter '*.md' -File -Recurse
  }
}
$files = @($files | Sort-Object LastWriteTime -Descending | Select-Object -First 10)

# Print handoff rules (always)
Write-Host '== LOREKEEPER: HANDOFF CONTEXT =='
Write-Host ''
Write-Host 'When summarizing this session for compaction, please follow these rules:'
Write-Host '1. Preserve the WHY behind every decision — not just what was done, but why that approach was chosen and what alternatives were rejected.'
Write-Host '2. Keep exact file paths and line numbers that were read or modified.'
Write-Host '3. Keep error messages and stack traces verbatim when they informed a diagnosis or fix.'
Write-Host '4. State current task status: what is complete, what is in progress, what is blocked and by what.'
Write-Host '5. If this context already contains a previous compaction summary, carry its key points forward — do not discard prior history.'
Write-Host '6. Preserve any blockers and dependencies between tasks.'

# Print notes/docs if any exist
if ($files.Count -gt 0) {
  Write-Host ''
  Write-Host 'The following notes from previous sessions may provide relevant context.'
  Write-Host 'Preserve any insights from these notes that are relevant to the current work:'
  Write-Host ''

  $notesNorm = $notesDir.Replace('/', '\').TrimEnd('\') + '\'

  foreach ($f in $files) {
    $fullPath = $f.FullName
    # Determine type: note vs doc
    if ($fullPath.Replace('/', '\').StartsWith($notesNorm)) {
      $type = 'note'
    } else {
      $type = 'doc'
    }
    $label = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
    $content = Get-Content -Raw -Path $fullPath -ErrorAction SilentlyContinue
    if (-not $content) { continue }

    # Cap at 1500 chars
    if ($content.Length -gt 1500) {
      $content = $content.Substring(0, 1500)
    }

    Write-Host "--- ${type}: ${label} ---"
    Write-Host $content
    Write-Host ''
  }
}

exit 0

#Requires -Version 5.1
# lorekeeper: PostToolUse hook (Windows/PowerShell)
# When Claude writes under $LOREKEEPER_HOME, kick off a background reindex so
# the new content is searchable in the next turn. Non-blocking.

$ErrorActionPreference = 'SilentlyContinue'

$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$homeFile = Join-Path $ClaudeDir '.lorekeeper-home'
$LorekeeperHome = if (Test-Path $homeFile) { (Get-Content -Raw $homeFile).Trim() } else { Join-Path $env:LOCALAPPDATA 'lorekeeper' }

$inputRaw = [Console]::In.ReadToEnd()
$data = $null
try { if ($inputRaw) { $data = $inputRaw | ConvertFrom-Json } } catch { exit 0 }
if (-not $data) { exit 0 }

$filePath = $null
if ($data.tool_input) {
  if ($data.tool_input.file_path) { $filePath = [string]$data.tool_input.file_path }
  elseif ($data.tool_input.path)  { $filePath = [string]$data.tool_input.path }
}
if (-not $filePath) { exit 0 }

# Resolve absolute
try {
  if (-not [System.IO.Path]::IsPathRooted($filePath)) {
    $filePath = [System.IO.Path]::GetFullPath($filePath)
  } else {
    $filePath = [System.IO.Path]::GetFullPath($filePath)
  }
} catch { exit 0 }

if (-not (Test-Path $LorekeeperHome)) { exit 0 }
$homeAbs = (Resolve-Path $LorekeeperHome).Path.TrimEnd('\')

# Case-insensitive prefix check
$fpLower   = $filePath.ToLowerInvariant()
$homeLower = $homeAbs.ToLowerInvariant()
if (-not ($fpLower.StartsWith($homeLower + '\') -or $fpLower -eq $homeLower)) { exit 0 }

# Serialize concurrent reindexes with a directory-as-lock
$lockDir  = Join-Path $env:TEMP 'lorekeeper'
New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
$lockPath = Join-Path $lockDir 'reindex.lock.d'

try {
  New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null
} catch {
  exit 0  # another reindex in flight
}

# Spawn detached background reindex; child removes the lock when done
$escapedLock = $lockPath.Replace("'", "''")
$cmd = "try { & qmd update; & qmd embed } finally { Remove-Item -LiteralPath '$escapedLock' -Recurse -Force -ErrorAction SilentlyContinue }"
Start-Process -WindowStyle Hidden -FilePath 'powershell' `
  -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Command',$cmd | Out-Null

exit 0

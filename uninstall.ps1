#Requires -Version 5.1
<#
.SYNOPSIS
  lorekeeper uninstaller (Windows) — removes hooks, CLAUDE.md block, qmd collections.
  Leaves notes/docs untouched.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$BinDir    = if ($env:LOREKEEPER_BIN)    { $env:LOREKEEPER_BIN }    else { Join-Path $env:LOCALAPPDATA 'lorekeeper\bin' }

function Say($m) { Write-Host "==> $m" -ForegroundColor Blue }

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  $enc = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

# --- hook files ---
Say 'removing hook scripts'
Remove-Item -Force -ErrorAction SilentlyContinue `
  (Join-Path $ClaudeDir 'hooks\lorekeeper-prime.ps1'), `
  (Join-Path $ClaudeDir 'hooks\lorekeeper-reindex.ps1'), `
  (Join-Path $ClaudeDir 'hooks\lorekeeper-autonote.ps1')

# --- scrub settings.json ---
$Settings = Join-Path $ClaudeDir 'settings.json'
if (Test-Path $Settings) {
  Say "scrubbing hook entries from $Settings"
  $json = Get-Content -Raw $Settings | ConvertFrom-Json
  if ($json -and $json.PSObject.Properties['hooks']) {
    foreach ($evt in 'SessionStart','UserPromptSubmit','PostToolUse','SessionEnd') {
      if ($json.hooks.PSObject.Properties[$evt]) {
        $entries = @($json.hooks.$evt)
        $kept = @()
        foreach ($e in $entries) {
          if ($e -and $e.hooks) {
            $filteredHooks = @($e.hooks | Where-Object {
              ($_.command -as [string]) -notmatch 'lorekeeper-(prime|reindex|autonote)\.ps1'
            })
            if ($filteredHooks.Count -gt 0) {
              $e.hooks = $filteredHooks
              $kept += $e
            }
          } else {
            $kept += $e
          }
        }
        $json.hooks | Add-Member -NotePropertyName $evt -NotePropertyValue $kept -Force
      }
    }
    Write-Utf8NoBom $Settings ($json | ConvertTo-Json -Depth 20)
  }
}

# --- CLAUDE.md block ---
$ClaudeMd = Join-Path $ClaudeDir 'CLAUDE.md'
if (Test-Path $ClaudeMd) {
  $current = Get-Content -Raw $ClaudeMd
  if ($current -and $current.Contains('<!-- LOREKEEPER:START -->')) {
    Say "removing policy block from $ClaudeMd"
    $pattern = "(?s)" + [regex]::Escape('<!-- LOREKEEPER:START -->') + ".*?" + [regex]::Escape('<!-- LOREKEEPER:END -->') + "\r?\n?"
    $new = [regex]::Replace($current, $pattern, '')
    Write-Utf8NoBom $ClaudeMd $new
  }
}

# --- qmd collections ---
Say 'removing qmd collections (notes + docs)'
& qmd collection remove lorekeeper-notes 2>$null | Out-Null
& qmd collection remove lorekeeper-docs  2>$null | Out-Null

# --- CLI + state ---
Remove-Item -Force -ErrorAction SilentlyContinue `
  (Join-Path $BinDir 'lorekeeper.ps1'), `
  (Join-Path $BinDir 'lorekeeper.cmd')

# Strip BinDir from user PATH (and current session)
$userPath = [Environment]::GetEnvironmentVariable('Path','User')
if ($userPath) {
  $binNorm = $BinDir.TrimEnd('\')
  $kept = @(($userPath -split ';') | Where-Object { $_ -and ($_.TrimEnd('\') -ine $binNorm) })
  $newUserPath = ($kept -join ';')
  if ($newUserPath -ne $userPath) {
    [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
    Say "removed $BinDir from user PATH"
  }
}
$env:Path = (($env:Path -split ';') | Where-Object { $_ -and ($_.TrimEnd('\') -ine $BinDir.TrimEnd('\')) }) -join ';'

# Remove empty BinDir (only if we own the whole lorekeeper tree under LOCALAPPDATA)
if ((Test-Path $BinDir) -and ((Get-ChildItem -Force $BinDir -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0)) {
  Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $BinDir
}

$homeFile = Join-Path $ClaudeDir '.lorekeeper-home'
$savedHome = if (Test-Path $homeFile) { (Get-Content -Raw $homeFile).Trim() } else { '' }
Remove-Item -Force -ErrorAction SilentlyContinue $homeFile

Write-Host ''
Write-Host 'uninstalled. your notes and docs are still at:'
if ($savedHome) { Write-Host "  $savedHome" } else { Write-Host '  (see $env:LOCALAPPDATA\lorekeeper)' }
Write-Host ''
Write-Host 'delete them by hand if you want them gone.'

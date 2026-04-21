#Requires -Version 5.1
<#
.SYNOPSIS
  lorekeeper installer (Windows) — idempotent.
  Native PowerShell port of install.sh. No bash/jq dependency.
#>

[CmdletBinding()]
param(
  [string]$LorekeeperHome,
  [switch]$WithCaveman,
  [switch]$NoCaveman,
  [switch]$NoEmbedBootstrap
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DefaultHome = Join-Path $env:LOCALAPPDATA 'lorekeeper'
if (-not $LorekeeperHome) { $LorekeeperHome = $DefaultHome }
$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }

function Say  ($m) { Write-Host "==> $m" -ForegroundColor Blue }
function Warn ($m) { Write-Host "!! $m"  -ForegroundColor Yellow }
function Die  ($m) { Write-Host "xx $m"  -ForegroundColor Red; exit 1 }

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  $enc = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Find-ShExe {
  if ($env:LOREKEEPER_SH -and (Test-Path $env:LOREKEEPER_SH)) { return $env:LOREKEEPER_SH }
  $candidates = @(
    (Join-Path $env:ProgramFiles 'Git\bin\sh.exe'),
    (Join-Path $env:ProgramFiles 'Git\usr\bin\sh.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\sh.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\sh.exe')
  )
  foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
  $cmd = Get-Command sh.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

# qmd's npm bin is a POSIX shell script. npm's generated shims hardcode
# "/bin/sh.exe" which doesn't exist on native Windows, so we rewrite the
# shims to invoke Git Bash's sh.exe + the qmd bin script directly.
function Repair-QmdShim {
  $npmPrefix = (& npm prefix -g 2>$null)
  if ($LASTEXITCODE -ne 0 -or -not $npmPrefix) { Warn 'npm prefix -g failed; skipping qmd shim repair'; return }
  $npmPrefix = ([string]$npmPrefix).Trim()
  $qmdBin = Join-Path $npmPrefix 'node_modules\@tobilu\qmd\bin\qmd'
  if (-not (Test-Path $qmdBin)) { Warn "qmd bin not found at $qmdBin; skipping shim repair"; return }
  $sh = Find-ShExe
  if (-not $sh) {
    Warn 'sh.exe not found. qmd ships a POSIX script and needs Git for Windows.'
    Warn 'install from https://git-scm.com/download/win then re-run this installer.'
    Die  'aborting - qmd unusable without sh.'
  }
  Say "repairing qmd shims to use: $sh"
  $ps1Path = Join-Path $npmPrefix 'qmd.ps1'
  $cmdPath = Join-Path $npmPrefix 'qmd.cmd'
  $shEsc  = $sh.Replace("'", "''")
  $binEsc = $qmdBin.Replace("'", "''")
  $ps1 = @"
#!/usr/bin/env pwsh
if (`$MyInvocation.ExpectingInput) {
  `$input | & '$shEsc' '$binEsc' `$args
} else {
  & '$shEsc' '$binEsc' `$args
}
exit `$LASTEXITCODE
"@
  Write-Utf8NoBom $ps1Path $ps1
  $cmdTxt = "@ECHO off`r`n`"$sh`" `"$qmdBin`" %*`r`n"
  [System.IO.File]::WriteAllText($cmdPath, $cmdTxt, (New-Object System.Text.UTF8Encoding $false))
}

if ($WithCaveman -and $NoCaveman) { Die '--WithCaveman and --NoCaveman are mutually exclusive' }

# --- preflight ---
foreach ($c in 'git','node') {
  if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { Die "$c not found on PATH" }
}

if (-not (Get-Command qmd -ErrorAction SilentlyContinue)) {
  Say 'qmd not found - installing @tobilu/qmd globally via npm'
  npm install -g '@tobilu/qmd'
  if ($LASTEXITCODE -ne 0) { Die 'qmd install failed. try: npm install -g @tobilu/qmd' }
}

# qmd's shim is broken on native Windows - patch it before first use.
Repair-QmdShim

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  Warn 'claude CLI not on PATH. Install Claude Code first: https://code.claude.com'
}

# --- caveman detection ---
$CavemanActive = $false
if ($WithCaveman) {
  if (Get-Command claude -ErrorAction SilentlyContinue) {
    Say 'installing caveman plugin'
    & claude plugin marketplace add JuliusBrussee/caveman 2>$null | Out-Null
    & claude plugin install caveman@caveman 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Warn "caveman install returned non-zero; check with 'claude plugin list'" }
  }
  $CavemanActive = $true
} elseif (-not $NoCaveman) {
  if (Get-Command claude -ErrorAction SilentlyContinue) {
    $list = & claude plugin list 2>$null
    if ($LASTEXITCODE -eq 0 -and ($list -match 'caveman')) {
      Say 'caveman plugin detected — using compressed CLAUDE.md'
      $CavemanActive = $true
    }
  }
}

# --- directories ---
Say "creating lorekeeper home: $LorekeeperHome"
New-Item -ItemType Directory -Force -Path `
  (Join-Path $LorekeeperHome 'notes'), `
  (Join-Path $LorekeeperHome 'docs'),  `
  (Join-Path $ClaudeDir 'hooks') | Out-Null

Write-Utf8NoBom (Join-Path $ClaudeDir '.lorekeeper-home') $LorekeeperHome

# --- copy hooks ---
Say "installing hooks to $ClaudeDir\hooks"
Copy-Item -Force (Join-Path $ScriptDir 'hooks\prime.ps1')   (Join-Path $ClaudeDir 'hooks\lorekeeper-prime.ps1')
Copy-Item -Force (Join-Path $ScriptDir 'hooks\reindex.ps1') (Join-Path $ClaudeDir 'hooks\lorekeeper-reindex.ps1')

# --- install bin ---
$BinDir = if ($env:LOREKEEPER_BIN) { $env:LOREKEEPER_BIN } else { Join-Path $env:LOCALAPPDATA 'lorekeeper\bin' }
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
Copy-Item -Force (Join-Path $ScriptDir 'bin\lorekeeper.ps1') (Join-Path $BinDir 'lorekeeper.ps1')
Copy-Item -Force (Join-Path $ScriptDir 'bin\lorekeeper.cmd') (Join-Path $BinDir 'lorekeeper.cmd')
Say "installed CLI: $BinDir\lorekeeper.cmd"

# Add BinDir to user PATH (persistent). Also patch the current session so the
# rest of this install and the caller's shell can use `lorekeeper` immediately.
$userPath = [Environment]::GetEnvironmentVariable('Path','User')
if (-not $userPath) { $userPath = '' }
$binNorm = $BinDir.TrimEnd('\')
$onUserPath = ($userPath -split ';') | Where-Object { $_ -and ($_.TrimEnd('\') -ieq $binNorm) }
if (-not $onUserPath) {
  $newUserPath = if ($userPath) { "$BinDir;$userPath" } else { $BinDir }
  [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
  Say "added $BinDir to user PATH"
} else {
  Say "$BinDir already on user PATH"
}
$onProcPath = ($env:Path -split ';') | Where-Object { $_ -and ($_.TrimEnd('\') -ieq $binNorm) }
if (-not $onProcPath) { $env:Path = "$BinDir;$env:Path" }

# --- settings.json merge ---
$Settings = Join-Path $ClaudeDir 'settings.json'
Say "merging hook config into $Settings"
if (-not (Test-Path $Settings)) { Write-Utf8NoBom $Settings '{}' }

$json = Get-Content -Raw $Settings | ConvertFrom-Json
if ($null -eq $json) { $json = [pscustomobject]@{} }
if (-not $json.PSObject.Properties['hooks']) {
  $json | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
}

$primeCmd   = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$ClaudeDir\hooks\lorekeeper-prime.ps1`""
$reindexCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$ClaudeDir\hooks\lorekeeper-reindex.ps1`""

function Ensure-HookEntry {
  param($Root, [string]$Event, [string]$Cmd, [string]$Matcher)
  $existing = @()
  if ($Root.hooks.PSObject.Properties[$Event]) { $existing = @($Root.hooks.$Event) }
  # drop previous entries pointing at same command
  $filtered = @($existing | Where-Object {
    $hasMatch = $false
    if ($_ -and $_.hooks) {
      foreach ($h in $_.hooks) { if ($h.command -eq $Cmd) { $hasMatch = $true; break } }
    }
    -not $hasMatch
  })
  $entryProps = [ordered]@{}
  if ($Matcher) { $entryProps.matcher = $Matcher }
  $entryProps.hooks = @([pscustomobject]@{ type = 'command'; command = $Cmd })
  $filtered += [pscustomobject]$entryProps
  $Root.hooks | Add-Member -NotePropertyName $Event -NotePropertyValue $filtered -Force
}

Ensure-HookEntry -Root $json -Event 'SessionStart'     -Cmd $primeCmd   -Matcher $null
Ensure-HookEntry -Root $json -Event 'UserPromptSubmit' -Cmd $primeCmd   -Matcher $null
Ensure-HookEntry -Root $json -Event 'PostToolUse'      -Cmd $reindexCmd -Matcher 'Write|Edit'

Write-Utf8NoBom $Settings ($json | ConvertTo-Json -Depth 20)

# --- CLAUDE.md injection ---
$ClaudeMd = Join-Path $ClaudeDir 'CLAUDE.md'
$TemplateKey = if ($CavemanActive) { 'CLAUDE.caveman.md' } else { 'CLAUDE.md' }
$Template = Join-Path $ScriptDir "templates\$TemplateKey"
Say "injecting policy block into $ClaudeMd (source: $TemplateKey)"
if (-not (Test-Path $ClaudeMd)) { New-Item -ItemType File -Path $ClaudeMd -Force | Out-Null }

$block = (Get-Content -Raw $Template).Replace('__LOREKEEPER_HOME__', $LorekeeperHome)
$start = '<!-- LOREKEEPER:START -->'
$end   = '<!-- LOREKEEPER:END -->'

$current = Get-Content -Raw $ClaudeMd
if ($null -eq $current) { $current = '' }

if ($current.Contains($start)) {
  $pattern = "(?s)" + [regex]::Escape($start) + ".*?" + [regex]::Escape($end)
  $replacement = "$start`r`n$block`r`n$end"
  $new = [regex]::Replace($current, $pattern, { param($m) $replacement })
  Write-Utf8NoBom $ClaudeMd $new
} else {
  $sep = ''
  if ($current.Length -gt 0 -and -not $current.EndsWith("`n")) { $sep = "`r`n" }
  $new = $current + $sep + "`r`n$start`r`n$block`r`n$end`r`n"
  Write-Utf8NoBom $ClaudeMd $new
}

# --- qmd collections ---
& (Join-Path $ScriptDir 'qmd\bootstrap.ps1') -LorekeeperHome $LorekeeperHome

if (-not $NoEmbedBootstrap) {
  Say 'generating initial embeddings (this takes a moment on first run)'
  qmd embed
  if ($LASTEXITCODE -ne 0) { Warn "qmd embed failed — run 'lorekeeper reindex' later" }
}

# --- done ---
$cavemanLabel = if ($CavemanActive) { 'active' } else { 'off' }
Write-Host ''
Write-Host 'installed.' -ForegroundColor Green
Write-Host ''
Write-Host "  home:     $LorekeeperHome"
Write-Host "  hooks:    $ClaudeDir\hooks\lorekeeper-{prime,reindex}.ps1"
Write-Host "  policy:   $ClaudeMd ($TemplateKey)"
Write-Host "  caveman:  $cavemanLabel"
Write-Host ''
Write-Host 'next:'
Write-Host '  1. open a Claude Code session in a git repo'
Write-Host "  2. run 'lorekeeper status' to verify wiring"
Write-Host "  3. seed a repo: 'lorekeeper note <repo> architecture'"

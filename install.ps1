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
  [switch]$NoEmbedBootstrap,
  [switch]$NoOmp,
  [switch]$NoClaude
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DefaultHome = Join-Path $env:LOCALAPPDATA 'lorekeeper'
if (-not $LorekeeperHome) { $LorekeeperHome = $DefaultHome }
$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$OmpDir = if ($env:OMP_CONFIG_DIR) { $env:OMP_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.omp' }

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
  (Join-Path $LorekeeperHome 'hooks') | Out-Null

# --- canonical hooks (consumed by both the Claude shim copies and the omp plugin) ---
Say "installing canonical hooks to $LorekeeperHome\hooks"
Copy-Item -Force (Join-Path $ScriptDir 'hooks\prime.ps1')    (Join-Path $LorekeeperHome 'hooks\prime.ps1')
Copy-Item -Force (Join-Path $ScriptDir 'hooks\reindex.ps1')  (Join-Path $LorekeeperHome 'hooks\reindex.ps1')
Copy-Item -Force (Join-Path $ScriptDir 'hooks\autonote.ps1') (Join-Path $LorekeeperHome 'hooks\autonote.ps1')
# bash siblings too (Git Bash users, WSL, etc.)
Copy-Item -Force (Join-Path $ScriptDir 'hooks\prime.sh')     (Join-Path $LorekeeperHome 'hooks\prime.sh')    -ErrorAction SilentlyContinue
Copy-Item -Force (Join-Path $ScriptDir 'hooks\reindex.sh')   (Join-Path $LorekeeperHome 'hooks\reindex.sh')  -ErrorAction SilentlyContinue
Copy-Item -Force (Join-Path $ScriptDir 'hooks\autonote.sh')  (Join-Path $LorekeeperHome 'hooks\autonote.sh') -ErrorAction SilentlyContinue

# --- Claude Code wiring ---
if (-not $NoClaude) {
  New-Item -ItemType Directory -Force -Path (Join-Path $ClaudeDir 'hooks') | Out-Null
  Write-Utf8NoBom (Join-Path $ClaudeDir '.lorekeeper-home') $LorekeeperHome
  Say "installing Claude-Code hook shims to $ClaudeDir\hooks"
  Copy-Item -Force (Join-Path $LorekeeperHome 'hooks\prime.ps1')    (Join-Path $ClaudeDir 'hooks\lorekeeper-prime.ps1')
  Copy-Item -Force (Join-Path $LorekeeperHome 'hooks\reindex.ps1')  (Join-Path $ClaudeDir 'hooks\lorekeeper-reindex.ps1')
  Copy-Item -Force (Join-Path $LorekeeperHome 'hooks\autonote.ps1') (Join-Path $ClaudeDir 'hooks\lorekeeper-autonote.ps1')
}

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

# --- Claude Code: settings.json hooks + CLAUDE.md injection ---
$ClaudeMd = $null
$ClaudeTemplateKey = $null
if (-not $NoClaude) {
  $Settings = Join-Path $ClaudeDir 'settings.json'
  Say "merging hook config into $Settings"
  if (-not (Test-Path $Settings)) { Write-Utf8NoBom $Settings '{}' }

  $json = Get-Content -Raw $Settings | ConvertFrom-Json
  if ($null -eq $json) { $json = [pscustomobject]@{} }
  if (-not $json.PSObject.Properties['hooks']) {
    $json | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
  }

  $primeCmd    = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$ClaudeDir\hooks\lorekeeper-prime.ps1`""
  $reindexCmd  = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$ClaudeDir\hooks\lorekeeper-reindex.ps1`""
  $autonoteCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$ClaudeDir\hooks\lorekeeper-autonote.ps1`""

  function Ensure-HookEntry {
    param($Root, [string]$HookEvent, [string]$Cmd, [string]$Matcher)
    $existing = @()
    if ($Root.hooks.PSObject.Properties[$HookEvent]) { $existing = @($Root.hooks.$HookEvent) }
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
    $Root.hooks | Add-Member -NotePropertyName $HookEvent -NotePropertyValue $filtered -Force
  }

  Ensure-HookEntry -Root $json -Event 'SessionStart'     -Cmd $primeCmd    -Matcher $null
  Ensure-HookEntry -Root $json -Event 'UserPromptSubmit' -Cmd $primeCmd    -Matcher $null
  Ensure-HookEntry -Root $json -Event 'PostToolUse'      -Cmd $reindexCmd  -Matcher 'Write|Edit'
  Ensure-HookEntry -Root $json -Event 'SessionEnd'       -Cmd $autonoteCmd -Matcher $null

  Write-Utf8NoBom $Settings ($json | ConvertTo-Json -Depth 20)

  # --- CLAUDE.md injection ---
  $ClaudeMd = Join-Path $ClaudeDir 'CLAUDE.md'
  $ClaudeTemplateKey = if ($CavemanActive) { 'CLAUDE.caveman.md' } else { 'CLAUDE.md' }
  $Template = Join-Path $ScriptDir "templates\$ClaudeTemplateKey"
  Say "injecting policy block into $ClaudeMd (source: $ClaudeTemplateKey)"
  if (-not (Test-Path $ClaudeMd)) { New-Item -ItemType File -Path $ClaudeMd -Force | Out-Null }

  $block = (Get-Content -Raw $Template).Replace('__LOREKEEPER_HOME__', $LorekeeperHome)
  $start = '<!-- LOREKEEPER:START -->'
  $end   = '<!-- LOREKEEPER:END -->'

  $current = Get-Content -Raw $ClaudeMd
  if ($null -eq $current) { $current = '' }

  if ($current.Contains($start)) {
    $pattern = "(?s)" + [regex]::Escape($start) + ".*?" + [regex]::Escape($end)
    $replacement = "$start`r`n$block`r`n$end"
    $new = [regex]::Replace($current, $pattern, { $replacement })
    Write-Utf8NoBom $ClaudeMd $new
  } else {
    $sep = ''
    if ($current.Length -gt 0 -and -not $current.EndsWith("`n")) { $sep = "`r`n" }
    $new = $current + $sep + "`r`n$start`r`n$block`r`n$end`r`n"
    Write-Utf8NoBom $ClaudeMd $new
  }
}

# --- omp plugin install ---
$OmpInstalled = $false
$OmpPluginPath = Join-Path $ScriptDir 'omp-plugin'
$OmpPluginInstalled = $null
if (-not $NoOmp -and (Test-Path $OmpPluginPath)) {
  $ompCli = Get-Command omp -ErrorAction SilentlyContinue
  $bunCli = Get-Command bun -ErrorAction SilentlyContinue
  if (-not $ompCli) {
    Say 'omp CLI not on PATH — skipping omp plugin install (rerun after installing omp)'
  } elseif (-not $bunCli) {
    Warn 'omp detected but bun CLI is missing — install bun (https://bun.sh) then re-run this installer'
  } else {
    Say 'building omp plugin'
    Push-Location $OmpPluginPath
    try {
      bun install
      if ($LASTEXITCODE -ne 0) { throw "bun install failed in $OmpPluginPath" }
      bun run build
      if ($LASTEXITCODE -ne 0) { throw "bun run build failed in $OmpPluginPath" }
    } finally {
      Pop-Location
    }

    # marker file: lets the plugin (and the canonical hooks) find $LOREKEEPER_HOME
    # without depending on Claude's config dir existing.
    New-Item -ItemType Directory -Force -Path $OmpDir | Out-Null
    Write-Utf8NoBom (Join-Path $OmpDir '.lorekeeper-home') $LorekeeperHome

    # register the plugin under ~/.omp/plugins/ via symlink (no npm publish required)
    $PluginsDir = Join-Path $OmpDir 'plugins'
    $PluginsNm  = Join-Path $PluginsDir 'node_modules'
    $ScopeDir   = Join-Path $PluginsNm '@lorekeeper'
    $LinkPath   = Join-Path $ScopeDir 'omp-plugin'
    New-Item -ItemType Directory -Force -Path $ScopeDir | Out-Null

    # remove stale link/dir
    if (Test-Path $LinkPath) {
      $item = Get-Item $LinkPath -Force
      if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        # symlink/junction — unlink without recursion
        [System.IO.Directory]::Delete($LinkPath, $false)
      } else {
        Remove-Item -Recurse -Force $LinkPath
      }
    }

    # try a real symlink first (needs developer mode / admin), fall back to a directory junction.
    $linked = $false
    try {
      New-Item -ItemType SymbolicLink -Path $LinkPath -Target $OmpPluginPath -ErrorAction Stop | Out-Null
      $linked = $true
    } catch {
      try {
        New-Item -ItemType Junction -Path $LinkPath -Target $OmpPluginPath -ErrorAction Stop | Out-Null
        $linked = Test-Path $LinkPath
      } catch { $linked = $false }
    }
    if (-not $linked) { Die "failed to link omp plugin: $LinkPath" }
    Say "linked omp plugin: $LinkPath -> $OmpPluginPath"

    # update ~/.omp/plugins/package.json so omp's loader sees the dep
    $PluginsPkg = Join-Path $PluginsDir 'package.json'
    if (-not (Test-Path $PluginsPkg)) {
      Write-Utf8NoBom $PluginsPkg '{"name":"omp-plugins","private":true,"dependencies":{}}'
    }
    $pkgJson = Get-Content -Raw $PluginsPkg | ConvertFrom-Json
    if ($null -eq $pkgJson) { $pkgJson = [pscustomobject]@{ name = 'omp-plugins'; private = $true; dependencies = [pscustomobject]@{} } }
    if (-not $pkgJson.PSObject.Properties['dependencies']) {
      $pkgJson | Add-Member -NotePropertyName dependencies -NotePropertyValue ([pscustomobject]@{})
    }
    $pkgJson.dependencies | Add-Member -NotePropertyName '@lorekeeper/omp-plugin' -NotePropertyValue 'link:./node_modules/@lorekeeper/omp-plugin' -Force
    Write-Utf8NoBom $PluginsPkg ($pkgJson | ConvertTo-Json -Depth 20)

    # inject the policy block into ~/.omp/AGENTS.md (omp inherits AGENTS.md natively)
    $AgentsMd = Join-Path $OmpDir 'AGENTS.md'
    $OmpTemplateKey = if ($CavemanActive) { 'CLAUDE.caveman.md' } else { 'CLAUDE.md' }
    $Template = Join-Path $ScriptDir "templates\$OmpTemplateKey"
    Say "injecting policy block into $AgentsMd (source: $OmpTemplateKey)"
    if (-not (Test-Path $AgentsMd)) { New-Item -ItemType File -Path $AgentsMd -Force | Out-Null }
    $block = (Get-Content -Raw $Template).Replace('__LOREKEEPER_HOME__', $LorekeeperHome)
    $start = '<!-- LOREKEEPER:START -->'
    $end   = '<!-- LOREKEEPER:END -->'
    $current = Get-Content -Raw $AgentsMd
    if ($null -eq $current) { $current = '' }
    if ($current.Contains($start)) {
      $pattern = "(?s)" + [regex]::Escape($start) + ".*?" + [regex]::Escape($end)
      $replacement = "$start`r`n$block`r`n$end"
      $new = [regex]::Replace($current, $pattern, { $replacement })
      Write-Utf8NoBom $AgentsMd $new
    } else {
      $sep = ''
      if ($current.Length -gt 0 -and -not $current.EndsWith("`n")) { $sep = "`r`n" }
      $new = $current + $sep + "`r`n$start`r`n$block`r`n$end`r`n"
      Write-Utf8NoBom $AgentsMd $new
    }

    $OmpInstalled = $true
  }
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
Write-Host "  hooks:    $LorekeeperHome\hooks\{prime,reindex,autonote}.ps1 (canonical)"
if (-not $NoClaude) {
  Write-Host "  claude:   $ClaudeDir\hooks\lorekeeper-{prime,reindex,autonote}.ps1"
  Write-Host "  policy:   $ClaudeMd ($ClaudeTemplateKey)"
} else {
  Write-Host "  claude:   skipped (-NoClaude)"
}
if ($OmpInstalled) {
  Write-Host "  omp:      $OmpDir\plugins\node_modules\@lorekeeper\omp-plugin -> $OmpPluginPath"
  Write-Host "  agents:   $OmpDir\AGENTS.md"
} elseif (-not $NoOmp) {
  Write-Host "  omp:      not installed (CLI missing or skipped)"
} else {
  Write-Host "  omp:      skipped (-NoOmp)"
}
Write-Host "  caveman:  $cavemanLabel"
Write-Host ''
Write-Host 'next:'
Write-Host '  1. open a Claude Code or omp session in a git repo'
Write-Host "  2. run 'lorekeeper status' to verify wiring"
Write-Host "  3. seed a repo: 'lorekeeper note <repo> architecture'"

#Requires -Version 5.1
# lorekeeper CLI (Windows/PowerShell) — wrapper around qmd + filesystem ops.

$ErrorActionPreference = 'Stop'

$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$homeFile = Join-Path $ClaudeDir '.lorekeeper-home'
$LorekeeperHome = if (Test-Path $homeFile) { (Get-Content -Raw $homeFile).Trim() } else { Join-Path $env:LOCALAPPDATA 'lorekeeper' }

$TemplateNote = Join-Path $LorekeeperHome '.template-note.md'

$Usage = @'
lorekeeper <command> [args]

  status              install health check
  add-repo <name>     create notes/<name>/ and docs/<name>/ plus a qmd context
  note <repo> <slug>  open $EDITOR on a note (creates from template if missing)
  doc  <repo> <slug>  same, for docs
  ls [repo]           list notes/docs (optionally scoped to one repo)
  reindex             force qmd update + embed
  home                print lorekeeper home
  help                this message
'@

function Die($m) { Write-Host "xx $m" -ForegroundColor Red; exit 1 }

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  $enc = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Ensure-Template {
  if (-not (Test-Path $TemplateNote)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $TemplateNote) | Out-Null
    $tpl = @'
---
repo: __REPO__
topic: __SLUG__
date: __DATE__
tags: []
---

# __TITLE__

## context
<when/why this came up — 1-3 sentences>

## what i learned
<the actual content — bullets for gotchas, code refs as file:line>

## see also
<relative links or qmd:// refs>
'@
    Write-Utf8NoBom $TemplateNote $tpl
  }
}

function Open-Editor([string]$File) {
  $editor = if ($env:EDITOR) { $env:EDITOR } elseif ($env:VISUAL) { $env:VISUAL } else { 'notepad' }
  & $editor $File
}

function Open-Kind {
  param([string]$Kind, [string]$Repo, [string]$Slug)
  if (-not $Repo) { Die 'repo name required' }
  if (-not $Slug) { Die 'slug required' }
  $dir = Join-Path $LorekeeperHome "$Kind\$Repo"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $file = Join-Path $dir "$Slug.md"
  if (-not (Test-Path $file)) {
    Ensure-Template
    $body = (Get-Content -Raw $TemplateNote).
      Replace('__REPO__',  $Repo).
      Replace('__SLUG__',  $Slug).
      Replace('__DATE__',  (Get-Date -Format 'yyyy-MM-dd')).
      Replace('__TITLE__', $Slug)
    Write-Utf8NoBom $file $body
  }
  Open-Editor $file
  & qmd update 2>$null | Out-Null
  & qmd embed  2>$null | Out-Null
}

$cmd = if ($args.Count -ge 1) { $args[0] } else { 'help' }
$rest = @()
if ($args.Count -ge 2) { $rest = $args[1..($args.Count - 1)] }

switch ($cmd) {
  'home' { Write-Output $LorekeeperHome; break }

  { $_ -in 'help','-h','--help' } { Write-Output $Usage; break }

  'status' {
    Write-Output ("home:        " + $LorekeeperHome)
    if (Get-Command qmd -ErrorAction SilentlyContinue) {
      $ver = try { (& qmd --version 2>$null) } catch { 'unknown' }
      if (-not $ver) { $ver = 'unknown' }
      Write-Output ("qmd:         installed ({0})" -f $ver)
    } else {
      Write-Output 'qmd:         NOT FOUND'
    }
    Write-Output 'collections: '
    $cols = & qmd collection list 2>$null
    if ($cols) {
      $filtered = $cols | Select-String -Pattern 'lorekeeper-(notes|docs)'
      if ($filtered) { $filtered | ForEach-Object { Write-Output "  $_" } }
      else { Write-Output '  (none registered)' }
    } else { Write-Output '  (none registered)' }
    Write-Output ''
    Write-Output 'hooks:'
    foreach ($h in 'lorekeeper-prime.ps1','lorekeeper-reindex.ps1') {
      $p = Join-Path $ClaudeDir "hooks\$h"
      if (Test-Path $p) { Write-Output "  $h OK" } else { Write-Output "  $h MISSING" }
    }
    Write-Output ''
    $claudeMd = Join-Path $ClaudeDir 'CLAUDE.md'
    $blockOk  = $false
    if (Test-Path $claudeMd) {
      $blockOk = (Select-String -LiteralPath $claudeMd -SimpleMatch '<!-- LOREKEEPER:START -->' -Quiet)
    }
    Write-Output ("CLAUDE.md policy block: " + $(if ($blockOk) { 'present' } else { 'MISSING' }))
    $cavemanOn = $false
    if (Get-Command claude -ErrorAction SilentlyContinue) {
      $pl = & claude plugin list 2>$null
      if ($pl -and ($pl -match 'caveman')) { $cavemanOn = $true }
    }
    Write-Output ("caveman:     " + $(if ($cavemanOn) { 'active' } else { 'not installed' }))
    break
  }

  'add-repo' {
    $name = if ($rest.Count -ge 1) { $rest[0] } else { $null }
    if (-not $name) { Die 'usage: lorekeeper add-repo <name>' }
    New-Item -ItemType Directory -Force -Path `
      (Join-Path $LorekeeperHome "notes\$name"), `
      (Join-Path $LorekeeperHome "docs\$name") | Out-Null
    & qmd context add "qmd://lorekeeper-notes/$name" "Memory for repo '$name'" 2>$null | Out-Null
    & qmd context add "qmd://lorekeeper-docs/$name"  "Reference docs for repo '$name'" 2>$null | Out-Null
    Write-Output "registered '$name'"
    break
  }

  'note' {
    $repo = if ($rest.Count -ge 1) { $rest[0] } else { $null }
    $slug = if ($rest.Count -ge 2) { $rest[1] } else { $null }
    Open-Kind -Kind 'notes' -Repo $repo -Slug $slug
    break
  }

  'doc' {
    $repo = if ($rest.Count -ge 1) { $rest[0] } else { $null }
    $slug = if ($rest.Count -ge 2) { $rest[1] } else { $null }
    Open-Kind -Kind 'docs' -Repo $repo -Slug $slug
    break
  }

  'ls' {
    $repo = if ($rest.Count -ge 1) { $rest[0] } else { '' }
    if ($repo) {
      foreach ($kind in 'notes','docs') {
        $d = Join-Path $LorekeeperHome "$kind\$repo"
        if (-not (Test-Path $d)) { continue }
        Write-Output ''
        Write-Output "== $kind/$repo =="
        $root = (Resolve-Path $d).Path.TrimEnd('\')
        Get-ChildItem -Path $d -Recurse -Filter *.md -File -ErrorAction SilentlyContinue |
          ForEach-Object { "  " + $_.FullName.Substring($root.Length + 1).Replace('\','/') } |
          Sort-Object
      }
    } else {
      foreach ($kind in 'notes','docs') {
        Write-Output ''
        Write-Output "== $kind =="
        $base = Join-Path $LorekeeperHome $kind
        if (-not (Test-Path $base)) { continue }
        Get-ChildItem -Path $base -Directory -ErrorAction SilentlyContinue | ForEach-Object {
          $count = (Get-ChildItem -Path $_.FullName -Recurse -Filter *.md -File -ErrorAction SilentlyContinue | Measure-Object).Count
          "{0,-30} {1} file(s)" -f $_.Name, $count
        } | ForEach-Object { Write-Output "  $_" }
      }
    }
    break
  }

  'reindex' {
    & qmd update
    & qmd embed
    break
  }

  default { Die "unknown command: $cmd  (try: lorekeeper help)" }
}

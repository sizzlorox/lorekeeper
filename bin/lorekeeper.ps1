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
  distill [repo]      synthesize durable docs (architecture/runbook/onboarding/
                      conventions/api) from notes + codebase. Run from the
                      repo root; arg defaults to the current git toplevel name.
                      Uses Sonnet + tools; can take minutes and cost a few $.
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
    foreach ($h in 'lorekeeper-prime.ps1','lorekeeper-reindex.ps1','lorekeeper-autonote.ps1') {
      $p = Join-Path $ClaudeDir "hooks\$h"
      if (Test-Path $p) { Write-Output "  $h OK" } else { Write-Output "  $h MISSING" }
    }
    $autonoteOff = (Test-Path (Join-Path $LorekeeperHome '.autonote-off')) -or ($env:LOREKEEPER_AUTONOTE -eq 'off')
    Write-Output ("autonote:    " + $(if ($autonoteOff) { 'disabled' } else { 'enabled' }))
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

  'distill' {
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { Die 'claude CLI not on PATH' }
    $here = (Get-Location).Path
    Push-Location $here
    try {
      $top = & git rev-parse --show-toplevel 2>$null
    } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0 -or -not $top) { Die 'run this from inside a git worktree' }
    $topName = Split-Path $top.Trim() -Leaf
    $repoArg = if ($rest.Count -ge 1) { $rest[0] } else { $topName }
    if ($topName -ne $repoArg) {
      Die ("current git toplevel is '$topName', not '$repoArg' - cd into that worktree first")
    }
    $repo = $repoArg
    $notesDir = Join-Path $LorekeeperHome "notes\$repo"
    $docsDir  = Join-Path $LorekeeperHome "docs\$repo"
    New-Item -ItemType Directory -Force -Path $docsDir | Out-Null

    Write-Host "==> distilling durable docs for '$repo'" -ForegroundColor Blue
    Write-Host "    notes:  $notesDir"
    Write-Host "    docs:   $docsDir"
    Write-Host '    (this spawns Sonnet with Read/Glob/Grep/Write; may take minutes)'

    $today = (Get-Date).ToString('yyyy-MM-dd')
    $prompt = @"
You are generating durable engineering documentation for the repo at the current working directory (name: $repo).

INPUTS:
- Scratch notes are in: $notesDir (use Read/Glob to enumerate and load)
- Repo source is at the current working directory (use Glob/Grep/Read)

OUTPUTS (write each with the Write tool, only if you have substantive content):
- $docsDir\architecture.md   - system design, major components, data flow, key entry points
- $docsDir\onboarding.md     - getting started, env setup, first contribution walkthrough
- $docsDir\runbook.md        - ops procedures, deploy, rollback, debugging production
- $docsDir\conventions.md    - coding style, naming, patterns, testing conventions
- $docsDir\api.md            - public API reference (endpoints, types, commands); skip if the repo has no public surface

SAFETY:
- DO NOT modify any files outside $docsDir. Never Edit or Write into the repo source tree.
- If a target doc contains a block delimited by <!-- AUTODOC:START --> and <!-- AUTODOC:END -->, only rewrite content INSIDE those sentinels. Preserve everything outside verbatim.
- If a target doc exists and has NO sentinels, treat it as hand-curated: read it, merge respectfully (add sections, refine existing prose), do not wholesale replace it.

METHOD:
1. First, list and skim all notes under $notesDir.
2. Then scan the repo structure: top-level files, package/module layout, entry points, README, tests, CI config.
3. For each target doc, write content only if you have substantive grounded material. If you lack evidence for a section, omit it. Do NOT hallucinate features, endpoints, or configs.
4. Prefer concrete references: cite files as ``path:line`` or ``path``. Show real commands, not placeholders.
5. Keep prose terse: drop articles, fragments ok, technical identifiers exact.

OUTPUT DISCIPLINE:
- Each file starts with YAML frontmatter: ``repo: $repo``, ``type: <architecture|onboarding|runbook|conventions|api>``, ``updated: $today``.
- Use a single H1 matching the doc type, then H2 sections.
- When you finish, print a one-line summary of which files you wrote or updated.
"@

    $env:LOREKEEPER_AUTONOTE_CHILD = '1'
    & claude -p $prompt `
      --model claude-sonnet-4-6 `
      --add-dir $docsDir --add-dir $notesDir `
      --allowed-tools 'Read,Glob,Grep,Write' `
      --permission-mode bypassPermissions

    & qmd update 2>$null | Out-Null
    & qmd embed  2>$null | Out-Null
    break
  }

  default { Die "unknown command: $cmd  (try: lorekeeper help)" }
}

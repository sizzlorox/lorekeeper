#Requires -Version 5.1
# lorekeeper: SessionEnd hook (Windows) — autonomous extraction.
# Structural gate -> Haiku 4-way classifier -> Sonnet drafter routes to
# notes/, docs/<feature>.md, or docs/adr/ADR-NNNN-<slug>.md.

$ErrorActionPreference = 'SilentlyContinue'

# Recursion guard — skip when inside our own spawned classifier claude -p call.
if ($env:LOREKEEPER_AUTONOTE_CHILD -eq '1') { exit 0 }

$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$homeFile  = Join-Path $ClaudeDir '.lorekeeper-home'
$LorekeeperHome = if (Test-Path $homeFile) { (Get-Content -Raw $homeFile).Trim() } else { Join-Path $env:LOCALAPPDATA 'lorekeeper' }

if (Test-Path (Join-Path $LorekeeperHome '.autonote-off')) { exit 0 }
if ($env:LOREKEEPER_AUTONOTE -eq 'off') { exit 0 }
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { exit 0 }

$inputRaw = [Console]::In.ReadToEnd()
$data = $null
try { if ($inputRaw) { $data = $inputRaw | ConvertFrom-Json } } catch { exit 0 }
if (-not $data) { exit 0 }

$transcriptPath = [string]$data.transcript_path
$cwd            = [string]$data.cwd
$sessionId      = [string]$data.session_id

if (-not $transcriptPath -or -not (Test-Path $transcriptPath)) { exit 0 }
if (-not $cwd -or -not (Test-Path $cwd)) { exit 0 }

$repo = ''
Push-Location $cwd
try {
  $top = & git rev-parse --show-toplevel 2>$null
  if ($LASTEXITCODE -eq 0 -and $top) { $repo = Split-Path $top.Trim() -Leaf }
} finally { Pop-Location }
if (-not $repo) { exit 0 }

$seenDir = Join-Path $LorekeeperHome '.autonote-seen'
New-Item -ItemType Directory -Force -Path $seenDir | Out-Null
if ($sessionId) {
  $seenMarker = Join-Path $seenDir $sessionId
  if (Test-Path $seenMarker) { exit 0 }
  New-Item -ItemType File -Path $seenMarker -Force | Out-Null
}
Get-ChildItem $seenDir -File -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
  Remove-Item -Force -ErrorAction SilentlyContinue

# Worker script runs detached (SessionEnd has ~60s timeout, Sonnet runs longer).
$workerScript = @'
param(
  [string]$TranscriptPath,
  [string]$LorekeeperHome,
  [string]$Repo,
  [string]$SessionId
)
$ErrorActionPreference = 'SilentlyContinue'

$lines = Get-Content -LiteralPath $TranscriptPath -ErrorAction SilentlyContinue
if (-not $lines) { exit 0 }

$entries = @()
foreach ($ln in $lines) {
  if (-not $ln) { continue }
  try { $entries += ($ln | ConvertFrom-Json) } catch { }
}
if ($entries.Count -eq 0) { exit 0 }

# --- structural gate: tool_use count ---
$toolCount = 0
foreach ($e in $entries) {
  if ($e.type -ne 'assistant') { continue }
  $c = $e.message.content
  if ($c -is [System.Array]) {
    foreach ($part in $c) { if ($part.type -eq 'tool_use') { $toolCount++ } }
  }
}
if ($toolCount -lt 10) { exit 0 }

# --- signal gate ---
$fullText = ($lines -join "`n")
$signalPattern = '(?i)(error|exception|failed|traceback|turns out|instead|because|decided|doesn.t work|won.t work|gotcha|workaround|non.obvious|unexpected|surprise|shipped|done|finished|works now|ready|implemented|built)'
if ($fullText -notmatch $signalPattern) { exit 0 }

# --- condense ---
$sb = New-Object System.Text.StringBuilder
foreach ($e in $entries) {
  if ($e.type -ne 'user' -and $e.type -ne 'assistant') { continue }
  $c = $e.message.content
  $chunk = ''
  if ($c -is [string]) {
    $chunk = $c
  } elseif ($c -is [System.Array]) {
    $parts = @()
    foreach ($part in $c) {
      if ($part.type -eq 'text') { $parts += [string]$part.text }
      elseif ($part.type -eq 'tool_use') { $parts += "<tool:$($part.name)>" }
    }
    $chunk = ($parts -join ' ')
  }
  if ($chunk) { [void]$sb.AppendLine("[$($e.type)] $chunk") }
}
$condensed = $sb.ToString()
if ($condensed.Length -gt 60000) { $condensed = $condensed.Substring(0, 60000) }
if (-not $condensed.Trim()) { exit 0 }

# --- Haiku classifier ---
$gatePrompt = @"
You classify finished Claude Code sessions. Reply with EXACTLY ONE WORD on line 1: none, note, feature-doc, or adr.

- note: scratch memory for a SINGLE non-obvious learning — debug dead-end + fix, library/API quirk, config in an odd place, undocumented convention. Not ongoing.
- feature-doc: the session BUILT or substantially modified a nameable feature/subsystem future teammates would need onboarding docs for. Strong signal: new files/modules, components wired together, "shipped"/"done"/"works now" language, tests added.
- adr: an architectural or design DECISION was made with reasoning that will constrain future work. Strong signal: alternatives weighed, tradeoffs discussed, decision rationale articulated.
- none: nothing worth preserving cross-session.

Default to none unless clear. Between note and feature-doc, prefer note. Return ONE WORD on line 1, nothing else.

TRANSCRIPT:
$condensed
"@

$env:LOREKEEPER_AUTONOTE_CHILD = '1'
$gateOut = & claude -p $gatePrompt --model claude-haiku-4-5-20251001 --tools '' 2>$null
if (-not $gateOut) { exit 0 }
$firstRaw = ($gateOut -split "`n")[0]
$firstWord = ($firstRaw -split '\s+' | Where-Object { $_ })[0]
$gateFirst = if ($firstWord) { ($firstWord.ToLower() -replace '[^a-z-]','') } else { '' }

$kind = switch ($gateFirst) {
  'note'         { 'note' }
  'featuredoc'   { 'feature-doc' }
  'feature-doc'  { 'feature-doc' }
  'adr'          { 'adr' }
  default        { $null }
}
if (-not $kind) { exit 0 }

$today = (Get-Date).ToString('yyyy-MM-dd')

# --- per-kind prompt + output dir ---
$notesBase = Join-Path $LorekeeperHome "notes\$Repo"
$docsBase  = Join-Path $LorekeeperHome "docs\$Repo"
$adrBase   = Join-Path $docsBase 'adr'

if ($kind -eq 'note') {
  $outDir = $notesBase
  $draftPrompt = @"
Extract the single most memory-worthy learning from the following Claude Code session as a note. Output ONLY the note contents, no preamble, no code fence. Exact format:

---
repo: $Repo
topic: <2-5 words>
date: $today
tags: [<tag>, <tag>]
slug: <kebab-case-slug>
---

# <Title>

## context
<1-3 sentences: when/why this came up>

## what i learned
<bullets for gotchas. cite file:line where relevant. prose terse: drop articles, fragments ok. technical identifiers and error strings exact.>

## see also
<related files or external refs; omit section entirely if none>

Rules:
- Pick ONE specific learning.
- If nothing is truly non-obvious, output literally: SKIP
- slug kebab-case, no spaces.

TRANSCRIPT:
$condensed
"@
}
elseif ($kind -eq 'feature-doc') {
  $outDir = $docsBase
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null

  # Include existing feature docs (cap each at 3KB) so Sonnet can merge.
  $existingCtx = ''
  if (Test-Path $outDir) {
    Get-ChildItem -Path $outDir -Filter *.md -File -ErrorAction SilentlyContinue | ForEach-Object {
      $raw = Get-Content -Raw -LiteralPath $_.FullName -ErrorAction SilentlyContinue
      if ($raw) {
        if ($raw.Length -gt 3000) { $raw = $raw.Substring(0, 3000) }
        $existingCtx += "### existing doc: $($_.BaseName)`n$raw`n`n"
      }
    }
  }
  if (-not $existingCtx) { $existingCtx = '(no existing feature docs)' }

  $draftPrompt = @"
Write engineering feature documentation for the work done in this Claude Code session. Output ONLY the doc contents, no preamble, no code fence.

Existing feature docs for this repo are below — if this session EXTENDED one of them, reuse its slug and MERGE (preserve existing prose, add new sections/details, bump 'updated'). If this session built something NEW, pick a fresh slug.

$existingCtx

Exact output format:

---
repo: $Repo
type: feature
feature: <human-readable name>
date: <YYYY-MM-DD of first version; reuse from existing if merging, else $today>
updated: $today
slug: <kebab-case-slug>
---

# <Feature Name>

## overview
<1-2 paragraphs: what it does, who uses it, why it exists>

## how it works
<entry points, key files, control flow. cite code as ``path:line``>

## configuration
<env vars, settings, flags, defaults. omit section if none.>

## usage
<code examples, CLI invocations, API calls>

## see also
<related docs, external refs, code paths. omit section if none.>

Rules:
- If this session did NOT build or substantially modify a nameable feature, output literally: SKIP
- slug must be filesystem-safe kebab-case and stable across updates.
- When merging, keep content that's still accurate; don't drop sections unless contradicted.

TRANSCRIPT:
$condensed
"@
}
else { # adr
  $outDir = $adrBase
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null
  $lastNum = 0
  Get-ChildItem -Path $outDir -Filter 'ADR-*.md' -File -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.BaseName -match '^ADR-(\d+)') {
      $n = [int]$Matches[1]
      if ($n -gt $lastNum) { $lastNum = $n }
    }
  }
  $adrNum = 'ADR-{0:D4}' -f ($lastNum + 1)

  $draftPrompt = @"
Write an Architecture Decision Record (ADR) for the decision made in this Claude Code session. Output ONLY the ADR contents, no preamble, no code fence. Exact format:

---
repo: $Repo
type: adr
number: $adrNum
date: $today
status: accepted
slug: <kebab-case-slug>
---

# ${adrNum}: <Title>

## context
<forces at play, constraints, problem statement. 2-4 sentences.>

## decision
<what was decided, plainly stated>

## consequences
<positive outcomes, negative outcomes, tradeoffs. bullets ok.>

## alternatives considered
<other options evaluated, reasons rejected. bullets ok.>

Rules:
- If this session did NOT make a real architectural decision with reasoning, output literally: SKIP
- slug kebab-case, no spaces. Title short (5-10 words).

TRANSCRIPT:
$condensed
"@
}

$draft = & claude -p $draftPrompt --model claude-sonnet-4-6 --tools '' 2>$null
if (-not $draft) { exit 0 }
$draftText = ($draft -join "`n")
$firstLine = ($draftText -split "`n")[0].Trim()
if ($firstLine -eq 'SKIP') { exit 0 }

# Extract slug
$slug = ''
$fmCount = 0; $inFm = $false
foreach ($ln in ($draftText -split "`n")) {
  if ($ln.Trim() -eq '---') { $fmCount++; $inFm = ($fmCount -eq 1); continue }
  if ($inFm -and $ln -match '^\s*slug:\s*(.+?)\s*$') { $slug = $Matches[1]; break }
}
$slug = ($slug -replace '[^A-Za-z0-9_\-]','')
if (-not $slug) { $slug = "auto-$(Get-Date -UFormat %s)" }

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# Per-kind target path
$outPath = switch ($kind) {
  'note'        {
    $p = Join-Path $outDir "$slug.md"
    if (Test-Path $p) { $p = Join-Path $outDir ("$slug-" + (Get-Date -UFormat %s) + '.md') }
    $p
  }
  'feature-doc' { Join-Path $outDir "$slug.md" }   # overwrite on match (merge was Sonnet's job)
  'adr'         { Join-Path $outDir ($adrNum + '-' + $slug + '.md') }
}

# Strip slug: line from frontmatter
$outLines = @()
$fmCount = 0; $inFm = $false
foreach ($ln in ($draftText -split "`n")) {
  if ($ln.Trim() -eq '---') {
    $fmCount++; $inFm = ($fmCount -eq 1)
    $outLines += $ln; continue
  }
  if ($inFm -and $ln -match '^\s*slug:') { continue }
  $outLines += $ln
}
$enc = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($outPath, ($outLines -join "`r`n"), $enc)

if (Get-Command qmd -ErrorAction SilentlyContinue) {
  & qmd update 2>$null | Out-Null
  & qmd embed  2>$null | Out-Null
}

$logPath = Join-Path $LorekeeperHome '.autonote.log'
$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
Add-Content -LiteralPath $logPath -Value "[$stamp] $Repo [$kind]: $outPath (session $SessionId)"
'@

$workerPath = Join-Path $env:TEMP ("lorekeeper-autonote-" + [Guid]::NewGuid().ToString('N') + ".ps1")
$enc = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($workerPath, $workerScript, $enc)

$pwshArgs = @(
  '-NoProfile','-ExecutionPolicy','Bypass','-File', $workerPath,
  '-TranscriptPath', $transcriptPath,
  '-LorekeeperHome', $LorekeeperHome,
  '-Repo', $repo,
  '-SessionId', $sessionId
)
Start-Process -FilePath 'powershell' -ArgumentList $pwshArgs -WindowStyle Hidden | Out-Null

exit 0

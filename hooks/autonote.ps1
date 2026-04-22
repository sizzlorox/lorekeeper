#Requires -Version 5.1
# lorekeeper: SessionEnd hook (Windows) — autonomous note extraction.
# Structural gate -> Haiku classifier -> Sonnet drafter. Runs detached so
# SessionEnd returns fast (claude -p can take longer than the hook timeout).

$ErrorActionPreference = 'SilentlyContinue'

# Recursion guard — skip when inside our own spawned classifier claude -p call.
if ($env:LOREKEEPER_AUTONOTE_CHILD -eq '1') { exit 0 }

$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$homeFile  = Join-Path $ClaudeDir '.lorekeeper-home'
$LorekeeperHome = if (Test-Path $homeFile) { (Get-Content -Raw $homeFile).Trim() } else { Join-Path $env:LOCALAPPDATA 'lorekeeper' }

# Off switches
if (Test-Path (Join-Path $LorekeeperHome '.autonote-off')) { exit 0 }
if ($env:LOREKEEPER_AUTONOTE -eq 'off') { exit 0 }

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { exit 0 }

# Read hook input
$inputRaw = [Console]::In.ReadToEnd()
$data = $null
try { if ($inputRaw) { $data = $inputRaw | ConvertFrom-Json } } catch { exit 0 }
if (-not $data) { exit 0 }

$transcriptPath = [string]$data.transcript_path
$cwd            = [string]$data.cwd
$sessionId      = [string]$data.session_id

if (-not $transcriptPath -or -not (Test-Path $transcriptPath)) { exit 0 }
if (-not $cwd -or -not (Test-Path $cwd)) { exit 0 }

# Resolve repo name
$repo = ''
Push-Location $cwd
try {
  $top = & git rev-parse --show-toplevel 2>$null
  if ($LASTEXITCODE -eq 0 -and $top) { $repo = Split-Path $top.Trim() -Leaf }
} finally { Pop-Location }
if (-not $repo) { exit 0 }

# Dedup per session
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

# Background runner script — we write a temp .ps1 and start it detached.
$workerScript = @'
param(
  [string]$TranscriptPath,
  [string]$LorekeeperHome,
  [string]$Repo,
  [string]$SessionId
)
$ErrorActionPreference = 'SilentlyContinue'

# Parse transcript (JSONL)
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
$signalPattern = '(?i)(error|exception|failed|traceback|turns out|instead|because|decided|doesn.t work|won.t work|gotcha|workaround|non.obvious|unexpected|surprise)'
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

# --- Haiku gate ---
$gatePrompt = @"
You classify Claude Code session transcripts for NOTE-WORTHINESS.

Note-worthy = the session produced non-obvious knowledge a future session would benefit from:
- a debugging dead-end that cost >15 min with a non-obvious fix
- a library/API/system that behaved unexpectedly and required digging
- an architectural decision with reasoning
- a config/env var/secret in a non-obvious location
- an undocumented team convention

NOT note-worthy: quick lookups, pure codegen, formatting fixes, trivial Q&A, anything already covered by the repo README.

Reply with EXACTLY "yes" or "no" on the first line. Nothing else.

TRANSCRIPT:
$condensed
"@

$env:LOREKEEPER_AUTONOTE_CHILD = '1'
$gateOut = & claude -p $gatePrompt --model claude-haiku-4-5-20251001 --tools '' 2>$null
if (-not $gateOut) { exit 0 }
$firstRaw = ($gateOut -split "`n")[0]
$firstWord = ($firstRaw -split '\s+' | Where-Object { $_ })[0]
$gateFirst = if ($firstWord) { ($firstWord.ToLower() -replace '[^a-z]','') } else { '' }
if ($gateFirst -ne 'yes') { exit 0 }

# --- Sonnet draft ---
$today = (Get-Date).ToString('yyyy-MM-dd')
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
- Pick ONE specific learning. Best candidates: debug dead-end + fix, non-obvious API behavior, design decision + reasoning, config in odd location.
- If NOTHING is truly non-obvious or worth remembering cross-session, output literally: SKIP
- slug must be filesystem-safe kebab-case, no spaces.

TRANSCRIPT:
$condensed
"@

$draft = & claude -p $draftPrompt --model claude-sonnet-4-6 --tools '' 2>$null
if (-not $draft) { exit 0 }
$draftText = ($draft -join "`n")
$firstLine = ($draftText -split "`n")[0].Trim()
if ($firstLine -eq 'SKIP') { exit 0 }

# Extract slug
$slug = ''
$inFm = $false; $fmCount = 0
foreach ($ln in ($draftText -split "`n")) {
  if ($ln.Trim() -eq '---') { $fmCount++; $inFm = ($fmCount -eq 1); continue }
  if ($inFm -and $ln -match '^\s*slug:\s*(.+?)\s*$') { $slug = $Matches[1]; break }
}
$slug = ($slug -replace '[^A-Za-z0-9_\-]','')
if (-not $slug) { $slug = "auto-$(Get-Date -UFormat %s)" }

$notesDir = Join-Path $LorekeeperHome "notes\$Repo"
New-Item -ItemType Directory -Force -Path $notesDir | Out-Null
$notePath = Join-Path $notesDir "$slug.md"
if (Test-Path $notePath) { $notePath = Join-Path $notesDir "$slug-$(Get-Date -UFormat %s).md" }

# Write stripped of the slug: line (not part of canonical format)
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
[System.IO.File]::WriteAllText($notePath, ($outLines -join "`r`n"), $enc)

# Reindex (PostToolUse won't fire for our write)
if (Get-Command qmd -ErrorAction SilentlyContinue) {
  & qmd update 2>$null | Out-Null
  & qmd embed  2>$null | Out-Null
}

$logPath = Join-Path $LorekeeperHome '.autonote.log'
$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
Add-Content -LiteralPath $logPath -Value "[$stamp] $Repo`: auto-wrote $notePath (session $SessionId)"
'@

# Write worker to temp file and launch detached
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

#Requires -Version 5.1
# Register lorekeeper directories with qmd as two collections and attach
# collection-level contexts. Idempotent — safe to re-run.

param(
  [string]$LorekeeperHome
)

$ErrorActionPreference = 'Stop'

if (-not $LorekeeperHome) {
  $LorekeeperHome = if ($env:LOREKEEPER_HOME) { $env:LOREKEEPER_HOME } else { Join-Path $env:LOCALAPPDATA 'lorekeeper' }
}

function Say($m) { Write-Host "==> $m" -ForegroundColor Blue }

New-Item -ItemType Directory -Force -Path `
  (Join-Path $LorekeeperHome 'notes'), `
  (Join-Path $LorekeeperHome 'docs') | Out-Null

function Register-Collection {
  param([string]$Name, [string]$Path)
  $list = & qmd collection list 2>$null
  if ($list) {
    foreach ($line in $list) {
      if ($line -match "^\s*$([regex]::Escape($Name))(\s|$)") { return }
    }
  }
  Say "adding qmd collection: $Name -> $Path"
  & qmd collection add $Path --name $Name --mask '**/*.md'
}

Register-Collection -Name 'lorekeeper-notes' -Path (Join-Path $LorekeeperHome 'notes')
Register-Collection -Name 'lorekeeper-docs'  -Path (Join-Path $LorekeeperHome 'docs')

& qmd context add 'qmd://lorekeeper-notes' `
  "Session-to-session memory per repo - gotchas, decisions, debugging dead-ends, non-obvious behavior. Written in caveman-speak when caveman is active. Slug files under notes/<repo>/*.md." `
  2>$null | Out-Null

& qmd context add 'qmd://lorekeeper-docs' `
  "Durable reference docs per repo - overview, architecture, runbook, conventions. docs/<repo>/*.md. Stable, polished, handed to new teammates." `
  2>$null | Out-Null

Say 'qmd collections ready'

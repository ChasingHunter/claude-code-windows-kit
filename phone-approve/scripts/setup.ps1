# phone-approve one-time setup: asks for the Cloudflare Worker URL and the
# laptop secret (the same value you set with `wrangler secret put LAPTOP_SECRET`)
# and writes them to config.json. Run this after `npx wrangler deploy`.
#
# Safe to re-run: it shows your current values (secret masked) and lets you
# keep them by pressing Enter.

$ErrorActionPreference = 'Stop'

$dataDir = Join-Path $env:LOCALAPPDATA 'claude-code-windows-kit\phone-approve'
$configPath = Join-Path $dataDir 'config.json'

$existing = $null
if (Test-Path -LiteralPath $configPath) {
  try { $existing = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json } catch { $existing = $null }
}

function Read-WithDefault {
  param([string]$Prompt, [string]$Default)
  $suffix = if ($Default) { " [$Default]" } else { '' }
  $value = Read-Host "$Prompt$suffix"
  if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
  return $value
}

Write-Host 'phone-approve setup' -ForegroundColor Cyan
Write-Host 'Deploy the worker first (cd phone-approve/worker; npx wrangler deploy) if you have not already.'
Write-Host ''

$defaultUrl = if ($existing) { [string]$existing.workerUrl } else { '' }
$workerUrl = Read-WithDefault -Prompt 'Worker URL (e.g. https://phone-approve.your-subdomain.workers.dev)' -Default $defaultUrl
if ([string]::IsNullOrWhiteSpace($workerUrl)) {
  Write-Host 'A worker URL is required. Aborting.' -ForegroundColor Red
  exit 1
}

$maskedSecretHint = if ($existing -and $existing.secret) { '(press Enter to keep the current secret)' } else { '' }
Write-Host "Laptop secret $maskedSecretHint - the same value you ran 'wrangler secret put LAPTOP_SECRET' with:"
$secretInput = Read-Host -AsSecureString 'Secret'
$secret = $null
if ($secretInput -and $secretInput.Length -gt 0) {
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretInput)
  try { $secret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
if ([string]::IsNullOrWhiteSpace($secret)) {
  if ($existing -and $existing.secret) {
    $secret = [string]$existing.secret
  } else {
    Write-Host 'A secret is required. Aborting.' -ForegroundColor Red
    exit 1
  }
}

$defaultIdle = if ($existing -and $existing.idleMinutes) { [string]$existing.idleMinutes } else { '5' }
$idleMinutes = Read-WithDefault -Prompt 'Minutes idle before relaying to your phone' -Default $defaultIdle

$defaultTimeout = if ($existing -and $existing.timeoutMinutes) { [string]$existing.timeoutMinutes } else { '25' }
$timeoutMinutes = Read-WithDefault -Prompt 'Minutes to wait for a phone reply before giving up' -Default $defaultTimeout

$defaultPoll = if ($existing -and $existing.pollSeconds) { [string]$existing.pollSeconds } else { '2' }
$pollSeconds = Read-WithDefault -Prompt 'Seconds between polls while waiting' -Default $defaultPoll

$defaultAskMode = if ($existing -and $existing.askMode) { [string]$existing.askMode } else { 'denyWithAnswer' }
Write-Host ''
Write-Host 'askMode controls how answers to AskUserQuestion (clarifying questions) are'
Write-Host 'returned to Claude: "denyWithAnswer" (default, always works) feeds your phone'
Write-Host 'answers back as feedback text. "updatedInput" tries to answer the question'
Write-Host 'directly - only switch to it after you have confirmed it works live.'
$askMode = Read-WithDefault -Prompt 'askMode (denyWithAnswer/updatedInput)' -Default $defaultAskMode
if ($askMode -ne 'denyWithAnswer' -and $askMode -ne 'updatedInput') {
  Write-Host "Unrecognized askMode '$askMode'; using denyWithAnswer." -ForegroundColor Yellow
  $askMode = 'denyWithAnswer'
}

$config = [ordered]@{
  workerUrl      = $workerUrl.TrimEnd('/')
  secret         = $secret
  idleMinutes    = [int]$idleMinutes
  timeoutMinutes = [int]$timeoutMinutes
  pollSeconds    = [int]$pollSeconds
  askMode        = $askMode
}

New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
($config | ConvertTo-Json) | Set-Content -LiteralPath $configPath -Encoding utf8

Write-Host ''
Write-Host "Saved $configPath" -ForegroundColor Green
Write-Host 'Next: send your WhatsApp bot "hi" from your phone to open the 24h window, then'
Write-Host 'test with idleMinutes 0 (see README.md).'

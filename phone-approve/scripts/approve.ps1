# phone-approve hook: relays a PermissionRequest (any tool) or a PreToolUse
# AskUserQuestion call to WhatsApp when the laptop has been idle, waits for a
# tap/reply from the phone, and returns the decision to Claude Code.
#
# Handles two distinct hook events (see plugin.json):
#   - PermissionRequest (matcher "*"): the normal Approve/Deny flow for any
#     tool. Explicitly skips AskUserQuestion so it isn't double-handled.
#   - PreToolUse (matcher "AskUserQuestion"): answers clarifying questions.
#     PreToolUse — not PermissionRequest — is used here because Claude Code's
#     docs only document an `updatedInput` field alongside PreToolUse's
#     `permissionDecision`; PermissionRequest's decision object documents
#     only `behavior`/`message`/`updatedPermissions`, with no updatedInput.
#     PreToolUse also fires unconditionally before every tool call, so it's
#     guaranteed to run for AskUserQuestion regardless of how Claude Code's
#     interactive question UI is wired internally.
#
# Every exit path is exit 0. This hook must never block Claude Code or
# change flow via a non-zero exit — on any doubt, network failure, or
# unexpected input, it prints nothing and lets the normal local prompt show.

$ErrorActionPreference = 'Stop'

# --- Pure functions (dot-sourceable; no I/O, no globals) --------------------

function Get-PhoneApproveConfigPath {
  Join-Path $env:LOCALAPPDATA 'claude-code-windows-kit\phone-approve\config.json'
}

<#
.SYNOPSIS
Loads and validates config.json. Returns $null (never throws) for a missing
file, invalid JSON, or a config missing workerUrl/secret — callers treat a
null config as "fall through silently".
#>
function Get-PhoneApproveConfig {
  param([string]$Path = (Get-PhoneApproveConfigPath))

  if (-not (Test-Path -LiteralPath $Path)) { return $null }

  try {
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return $null
  }

  if (-not $cfg) { return $null }
  if (-not $cfg.workerUrl -or -not $cfg.secret) { return $null }

  $idleMinutes = 5
  if (($cfg.PSObject.Properties.Name -contains 'idleMinutes') -and $null -ne $cfg.idleMinutes) {
    $idleMinutes = [int]$cfg.idleMinutes
  }
  $timeoutMinutes = 25
  if (($cfg.PSObject.Properties.Name -contains 'timeoutMinutes') -and $null -ne $cfg.timeoutMinutes) {
    $timeoutMinutes = [int]$cfg.timeoutMinutes
  }
  $pollSeconds = 2
  if (($cfg.PSObject.Properties.Name -contains 'pollSeconds') -and $null -ne $cfg.pollSeconds) {
    $pollSeconds = [int]$cfg.pollSeconds
  }
  # askMode governs how AskUserQuestion answers are returned to Claude:
  #   denyWithAnswer (default, safe) - deny with the answers as feedback text.
  #   updatedInput   (best effort)   - allow + updatedInput.answers, mirroring
  #                                    the Agent SDK's canUseTool contract.
  #                                    Not confirmed to work for the CLI's
  #                                    PreToolUse hook path; opt in once
  #                                    you've verified it live.
  $askMode = 'denyWithAnswer'
  if (($cfg.PSObject.Properties.Name -contains 'askMode') -and $cfg.askMode) {
    $askMode = [string]$cfg.askMode
  }

  [PSCustomObject]@{
    workerUrl      = ([string]$cfg.workerUrl).TrimEnd('/')
    secret         = [string]$cfg.secret
    idleMinutes    = $idleMinutes
    timeoutMinutes = $timeoutMinutes
    pollSeconds    = $pollSeconds
    askMode        = $askMode
  }
}

<#
.SYNOPSIS
Builds the human-readable summary line sent to WhatsApp for a permission
prompt. Truncated so it stays well inside the 1024-char WhatsApp body limit
once wrapped in the worker's message template.
#>
function Build-Summary {
  param(
    [string]$ToolName,
    $ToolInput,
    [int]$MaxLength = 400
  )

  $text = $null
  switch ($ToolName) {
    'Bash' { $text = [string]$ToolInput.command }
    'Edit' { $text = [string]$ToolInput.file_path }
    'Write' { $text = [string]$ToolInput.file_path }
    'Read' { $text = [string]$ToolInput.file_path }
    'NotebookEdit' { $text = [string]$ToolInput.notebook_path }
    'WebFetch' { $text = [string]$ToolInput.url }
    default {
      try { $text = ($ToolInput | ConvertTo-Json -Compress -Depth 5 -ErrorAction Stop) }
      catch { $text = [string]$ToolInput }
    }
  }

  if ([string]::IsNullOrWhiteSpace($text)) { $text = '(no details)' }

  if ($text.Length -gt $MaxLength) {
    $cut = [Math]::Max(0, $MaxLength - 1)
    $text = $text.Substring(0, $cut) + [char]0x2026
  }

  return $text
}

<#
.SYNOPSIS
Builds the PermissionRequest hook's output JSON: allow or deny, per Claude
Code's documented decision shape (hookSpecificOutput.decision.behavior).
#>
function Build-DecisionJson {
  param(
    [ValidateSet('allow', 'deny')][string]$Behavior,
    [string]$Message
  )

  $decision = [ordered]@{ behavior = $Behavior }
  if ($Message) { $decision.message = $Message }

  $payload = [ordered]@{
    hookSpecificOutput = [ordered]@{
      hookEventName = 'PermissionRequest'
      decision      = $decision
    }
  }
  return ($payload | ConvertTo-Json -Depth 6 -Compress)
}

<#
.SYNOPSIS
Builds the PreToolUse hook's output JSON for an answered AskUserQuestion
call, in either askMode.
#>
function Build-AskUserQuestionDecisionJson {
  param(
    [ValidateSet('updatedInput', 'denyWithAnswer')][string]$AskMode = 'denyWithAnswer',
    [Parameter(Mandatory = $true)]$Questions,
    [Parameter(Mandatory = $true)]$Answers
  )

  function Get-AnswerFor($q) {
    if ($Answers -is [System.Collections.IDictionary]) { return $Answers[$q.question] }
    return $Answers.($q.question)
  }

  if ($AskMode -eq 'updatedInput') {
    $payload = [ordered]@{
      hookSpecificOutput = [ordered]@{
        hookEventName      = 'PreToolUse'
        permissionDecision = 'allow'
        updatedInput       = [ordered]@{
          questions = $Questions
          answers   = $Answers
        }
      }
    }
    return ($payload | ConvertTo-Json -Depth 10 -Compress)
  }

  $arrow = [char]0x2192
  $lines = @()
  foreach ($q in $Questions) {
    $answerText = Get-AnswerFor $q
    $lines += "The user answered from their phone (WhatsApp): `"$($q.question)`" $arrow $answerText. Treat this as the user's answer and continue."
  }
  $reason = [string]::Join("`n", $lines)

  $payload = [ordered]@{
    hookSpecificOutput = [ordered]@{
      hookEventName            = 'PreToolUse'
      permissionDecision       = 'deny'
      permissionDecisionReason = $reason
    }
  }
  return ($payload | ConvertTo-Json -Depth 6 -Compress)
}

<#
.SYNOPSIS
True once the laptop has been idle at least $IdleMinutes minutes.
IdleMinutes 0 always relays immediately (used for the manual smoke test).
#>
function Test-ShouldRelay {
  param(
    [long]$IdleMs,
    [int]$IdleMinutes
  )
  return ($IdleMs -ge ([long]$IdleMinutes * 60000L))
}

# --- Win32 idle-time + network helpers (impure; not unit tested) -----------

function Register-PhoneApproveIdleType {
  if (-not ([System.Management.Automation.PSTypeName]'PhoneApprove.IdleTime').Type) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace PhoneApprove {
  public static class IdleTime {
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static uint GetLastInputTick() {
      LASTINPUTINFO lii = new LASTINPUTINFO();
      lii.cbSize = (uint)Marshal.SizeOf(lii);
      GetLastInputInfo(ref lii);
      return lii.dwTime;
    }
  }
}
'@
  }
}

function Get-LastInputTick {
  Register-PhoneApproveIdleType
  return [PhoneApprove.IdleTime]::GetLastInputTick()
}

function Get-IdleMilliseconds {
  $tick = [Environment]::TickCount
  $lastInput = Get-LastInputTick
  $idle = $tick - $lastInput
  if ($idle -lt 0) { $idle = 0 } # tolerate TickCount wraparound (~49.7 days uptime)
  return [long]$idle
}

function Invoke-PhoneApproveApi {
  param(
    [Parameter(Mandatory = $true)]$Config,
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$Method = 'Get',
    $Body
  )
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $headers = @{ Authorization = "Bearer $($Config.secret)" }
  $params = @{
    Uri         = "$($Config.workerUrl)$Path"
    Method      = $Method
    Headers     = $headers
    TimeoutSec  = 15
    ErrorAction = 'Stop'
  }
  if ($null -ne $Body) {
    $params.Body = ($Body | ConvertTo-Json -Compress -Depth 10)
    $params.ContentType = 'application/json'
  }
  return Invoke-RestMethod @params
}

function Invoke-CreatePermissionRequest {
  param($Config, [string]$ToolName, [string]$Summary, [string]$CwdName, [string]$SessionId)
  try {
    $res = Invoke-PhoneApproveApi -Config $Config -Path '/requests' -Method Post -Body @{
      tool_name  = $ToolName
      summary    = $Summary
      cwd_name   = $CwdName
      session_id = $SessionId
    }
    return [string]$res.id
  } catch {
    return $null
  }
}

function Invoke-CreateQuestionRequest {
  param($Config, $Questions, [string]$CwdName, [string]$SessionId)
  try {
    $res = Invoke-PhoneApproveApi -Config $Config -Path '/requests' -Method Post -Body @{
      kind       = 'question'
      questions  = $Questions
      cwd_name   = $CwdName
      session_id = $SessionId
    }
    return [string]$res.id
  } catch {
    return $null
  }
}

<#
.SYNOPSIS
Polls the worker until it reports a terminal status, the laptop's local
input activity moves past $StartInputTick (user came back), or
timeoutMinutes elapses. Returns $null on timeout/activity/cancelled/expired
(caller falls through silently); otherwise a PSCustomObject with the
resolved status (and, for a question, its answers).
#>
function Wait-ForDecision {
  param($Config, [string]$Id, $StartInputTick)

  $deadline = (Get-Date).AddMinutes($Config.timeoutMinutes)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds ([Math]::Max(1, $Config.pollSeconds))

    if ((Get-LastInputTick) -ne $StartInputTick) { return $null } # user is back at the laptop

    try {
      $res = Invoke-PhoneApproveApi -Config $Config -Path "/requests/$Id"
    } catch {
      continue # transient network error; keep polling until the deadline
    }

    if ($res.status -eq 'allow' -or $res.status -eq 'deny' -or $res.status -eq 'answered') {
      return [PSCustomObject]@{ status = $res.status; answers = $res.answers }
    }
    if ($res.status -eq 'cancelled' -or $res.status -eq 'expired') { return $null }
  }
  return $null
}

function Invoke-CancelRequest {
  param($Config, [string]$Id)
  try { Invoke-PhoneApproveApi -Config $Config -Path "/requests/$Id/cancel" -Method Post | Out-Null } catch { }
}

function Write-PhoneApproveErrorLog {
  param([string]$Text)
  try {
    $dataDir = Join-Path $env:LOCALAPPDATA 'claude-code-windows-kit\phone-approve'
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
    Add-Content -Path (Join-Path $dataDir 'error.log') -Value "$(Get-Date -Format o) $Text"
  } catch { }
}

# --- Main --------------------------------------------------------------------
# Guarded so Pester can dot-source this file for the functions above without
# running any of the logic below.

if ($MyInvocation.InvocationName -ne '.') {
  try {
    # Read ALL of stdin before doing anything else: a hook blocked on stdin
    # ignores its own timeout, so this must never be deferred behind other
    # work.
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

    try { $hookData = $raw | ConvertFrom-Json -ErrorAction Stop } catch { exit 0 }
    if (-not $hookData) { exit 0 }

    $config = Get-PhoneApproveConfig
    if (-not $config) { exit 0 }

    $eventName = [string]$hookData.hook_event_name
    $toolName = [string]$hookData.tool_name
    $cwdName = if ($hookData.cwd) { Split-Path -Path ([string]$hookData.cwd) -Leaf } else { 'project' }

    if ($eventName -eq 'PreToolUse' -and $toolName -eq 'AskUserQuestion') {
      $questions = $hookData.tool_input.questions
      if (-not $questions) { exit 0 }

      if (-not (Test-ShouldRelay -IdleMs (Get-IdleMilliseconds) -IdleMinutes $config.idleMinutes)) { exit 0 }

      $startInputTick = Get-LastInputTick
      $id = Invoke-CreateQuestionRequest -Config $config -Questions $questions -CwdName $cwdName -SessionId ([string]$hookData.session_id)
      if (-not $id) { exit 0 }

      $result = Wait-ForDecision -Config $config -Id $id -StartInputTick $startInputTick
      if (-not $result -or $result.status -ne 'answered') {
        Invoke-CancelRequest -Config $config -Id $id
        exit 0
      }

      Write-Output (Build-AskUserQuestionDecisionJson -AskMode $config.askMode -Questions $questions -Answers $result.answers)
      exit 0
    }

    if ($eventName -eq 'PermissionRequest') {
      if ($toolName -eq 'AskUserQuestion') { exit 0 } # handled by the PreToolUse hook instead

      if (-not (Test-ShouldRelay -IdleMs (Get-IdleMilliseconds) -IdleMinutes $config.idleMinutes)) { exit 0 }

      $summary = Build-Summary -ToolName $toolName -ToolInput $hookData.tool_input
      $startInputTick = Get-LastInputTick
      $id = Invoke-CreatePermissionRequest -Config $config -ToolName $toolName -Summary $summary -CwdName $cwdName -SessionId ([string]$hookData.session_id)
      if (-not $id) { exit 0 }

      $result = Wait-ForDecision -Config $config -Id $id -StartInputTick $startInputTick
      if (-not $result -or ($result.status -ne 'allow' -and $result.status -ne 'deny')) {
        Invoke-CancelRequest -Config $config -Id $id
        exit 0
      }

      Write-Output (Build-DecisionJson -Behavior $result.status)
      exit 0
    }

    exit 0
  } catch {
    Write-PhoneApproveErrorLog $_.Exception.Message
    exit 0
  }
}

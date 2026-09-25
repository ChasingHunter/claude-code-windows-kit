# Pester tests for approve.ps1's pure, dot-sourceable functions.
#
# Written against Pester 3.4.0, the version that ships in-box with Windows
# PowerShell 5.1 (`Get-Module -ListAvailable Pester`) and the only version
# available on this machine. Assertions therefore use the legacy bareword
# operator syntax (`Should Be`, `Should Not Be`, ...) rather than Pester
# 4/5's dash-parameter syntax (`Should -Be`), since that's what Pester 3.4
# supports. This syntax is widely reported to still work under Pester 5's
# backward-compatible legacy assertions, but that was NOT independently
# verified here — only Pester 3.4 is installed on this machine. If you have
# Pester 5 installed separately, run this file there too before trusting it
# in that environment.
#
# approve.ps1 guards its main body behind
# `if ($MyInvocation.InvocationName -ne '.')`, so dot-sourcing it here runs
# only the function definitions, never the hook's stdin/network logic.

$scriptPath = Join-Path $PSScriptRoot '..\scripts\approve.ps1'
. $scriptPath

Describe 'Build-Summary' {
  It 'returns the command for Bash' {
    $result = Build-Summary -ToolName 'Bash' -ToolInput ([PSCustomObject]@{ command = 'ls -la' })
    $result | Should Be 'ls -la'
  }

  It 'returns the file_path for Edit' {
    $result = Build-Summary -ToolName 'Edit' -ToolInput ([PSCustomObject]@{ file_path = 'src\index.ts' })
    $result | Should Be 'src\index.ts'
  }

  It 'returns the file_path for Write' {
    $result = Build-Summary -ToolName 'Write' -ToolInput ([PSCustomObject]@{ file_path = 'notes.md' })
    $result | Should Be 'notes.md'
  }

  It 'returns the url for WebFetch' {
    $result = Build-Summary -ToolName 'WebFetch' -ToolInput ([PSCustomObject]@{ url = 'https://example.com' })
    $result | Should Be 'https://example.com'
  }

  It 'falls back to compact JSON of tool_input for an unknown tool' {
    $result = Build-Summary -ToolName 'SomeCustomTool' -ToolInput ([PSCustomObject]@{ foo = 'bar'; baz = 1 })
    $result | Should Match 'foo'
    $result | Should Match 'bar'
  }

  It 'truncates long text and appends an ellipsis' {
    $longCommand = 'x' * 500
    $result = Build-Summary -ToolName 'Bash' -ToolInput ([PSCustomObject]@{ command = $longCommand }) -MaxLength 50
    $result.Length | Should Be 50
    $result.Substring($result.Length - 1) | Should Be ([char]0x2026)
  }

  It 'does not truncate text shorter than MaxLength' {
    $result = Build-Summary -ToolName 'Bash' -ToolInput ([PSCustomObject]@{ command = 'short' }) -MaxLength 400
    $result | Should Be 'short'
  }
}

Describe 'Build-DecisionJson' {
  It 'builds the documented allow shape' {
    $json = Build-DecisionJson -Behavior 'allow'
    $parsed = $json | ConvertFrom-Json
    $parsed.hookSpecificOutput.hookEventName | Should Be 'PermissionRequest'
    $parsed.hookSpecificOutput.decision.behavior | Should Be 'allow'
  }

  It 'builds the documented deny shape with a message' {
    $json = Build-DecisionJson -Behavior 'deny' -Message 'Denied from phone'
    $parsed = $json | ConvertFrom-Json
    $parsed.hookSpecificOutput.hookEventName | Should Be 'PermissionRequest'
    $parsed.hookSpecificOutput.decision.behavior | Should Be 'deny'
    $parsed.hookSpecificOutput.decision.message | Should Be 'Denied from phone'
  }

  It 'omits the message field entirely when none is given' {
    $json = Build-DecisionJson -Behavior 'allow'
    $json | Should Not Match 'message'
  }
}

Describe 'Build-AskUserQuestionDecisionJson' {
  $questions = @([PSCustomObject]@{ question = 'Which approach?'; options = @([PSCustomObject]@{ label = 'A' }, [PSCustomObject]@{ label = 'B' }) })
  $answers = [PSCustomObject]@{ 'Which approach?' = 'A' }

  It 'builds a deny + reason shape in denyWithAnswer mode (the default)' {
    $json = Build-AskUserQuestionDecisionJson -AskMode 'denyWithAnswer' -Questions $questions -Answers $answers
    $parsed = $json | ConvertFrom-Json
    $parsed.hookSpecificOutput.hookEventName | Should Be 'PreToolUse'
    $parsed.hookSpecificOutput.permissionDecision | Should Be 'deny'
    $parsed.hookSpecificOutput.permissionDecisionReason | Should Match 'Which approach\?'
    $parsed.hookSpecificOutput.permissionDecisionReason | Should Match 'A'
    $parsed.hookSpecificOutput.permissionDecisionReason | Should Match "user's answer"
  }

  It 'builds an allow + updatedInput shape in updatedInput mode' {
    $json = Build-AskUserQuestionDecisionJson -AskMode 'updatedInput' -Questions $questions -Answers $answers
    $parsed = $json | ConvertFrom-Json
    $parsed.hookSpecificOutput.hookEventName | Should Be 'PreToolUse'
    $parsed.hookSpecificOutput.permissionDecision | Should Be 'allow'
    $parsed.hookSpecificOutput.updatedInput.answers.'Which approach?' | Should Be 'A'
  }

  It 'defaults to denyWithAnswer when no AskMode is given' {
    $json = Build-AskUserQuestionDecisionJson -Questions $questions -Answers $answers
    $parsed = $json | ConvertFrom-Json
    $parsed.hookSpecificOutput.permissionDecision | Should Be 'deny'
  }
}

Describe 'Test-ShouldRelay' {
  It 'is false when idle time is below the threshold' {
    Test-ShouldRelay -IdleMs 60000 -IdleMinutes 5 | Should Be $false
  }

  It 'is true when idle time meets the threshold exactly' {
    Test-ShouldRelay -IdleMs 300000 -IdleMinutes 5 | Should Be $true
  }

  It 'is true when idle time exceeds the threshold' {
    Test-ShouldRelay -IdleMs 999999 -IdleMinutes 5 | Should Be $true
  }

  It 'is always true when IdleMinutes is 0 (used for the manual smoke test)' {
    Test-ShouldRelay -IdleMs 0 -IdleMinutes 0 | Should Be $true
  }
}

Describe 'Get-PhoneApproveConfig' {
  It 'returns $null when the config file does not exist' {
    $missingPath = Join-Path $env:TEMP 'phone-approve-tests-missing-config.json'
    if (Test-Path $missingPath) { Remove-Item $missingPath -Force }
    Get-PhoneApproveConfig -Path $missingPath | Should Be $null
  }

  It 'returns $null for invalid JSON' {
    $badPath = Join-Path $env:TEMP 'phone-approve-tests-bad-config.json'
    Set-Content -LiteralPath $badPath -Value '{ not valid json'
    try {
      Get-PhoneApproveConfig -Path $badPath | Should Be $null
    } finally {
      Remove-Item $badPath -Force -ErrorAction SilentlyContinue
    }
  }

  It 'returns $null when workerUrl or secret is missing' {
    $incompletePath = Join-Path $env:TEMP 'phone-approve-tests-incomplete-config.json'
    Set-Content -LiteralPath $incompletePath -Value '{ "workerUrl": "https://example.com" }'
    try {
      Get-PhoneApproveConfig -Path $incompletePath | Should Be $null
    } finally {
      Remove-Item $incompletePath -Force -ErrorAction SilentlyContinue
    }
  }

  It 'loads a valid config and fills in defaults' {
    $goodPath = Join-Path $env:TEMP 'phone-approve-tests-good-config.json'
    Set-Content -LiteralPath $goodPath -Value '{ "workerUrl": "https://example.com/", "secret": "s3cr3t" }'
    try {
      $cfg = Get-PhoneApproveConfig -Path $goodPath
      $cfg.workerUrl | Should Be 'https://example.com'
      $cfg.secret | Should Be 's3cr3t'
      $cfg.idleMinutes | Should Be 5
      $cfg.timeoutMinutes | Should Be 25
      $cfg.pollSeconds | Should Be 2
      $cfg.askMode | Should Be 'denyWithAnswer'
    } finally {
      Remove-Item $goodPath -Force -ErrorAction SilentlyContinue
    }
  }

  It 'honors explicit overrides for idleMinutes/timeoutMinutes/pollSeconds/askMode' {
    $customPath = Join-Path $env:TEMP 'phone-approve-tests-custom-config.json'
    $body = '{ "workerUrl": "https://example.com", "secret": "s3cr3t", "idleMinutes": 0, "timeoutMinutes": 10, "pollSeconds": 1, "askMode": "updatedInput" }'
    Set-Content -LiteralPath $customPath -Value $body
    try {
      $cfg = Get-PhoneApproveConfig -Path $customPath
      $cfg.idleMinutes | Should Be 0
      $cfg.timeoutMinutes | Should Be 10
      $cfg.pollSeconds | Should Be 1
      $cfg.askMode | Should Be 'updatedInput'
    } finally {
      Remove-Item $customPath -Force -ErrorAction SilentlyContinue
    }
  }
}

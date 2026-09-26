$ErrorActionPreference = 'Stop'

# Claude Code sends UTF-8; Windows PowerShell's stdin defaults to the OEM code
# page, which would garble non-ASCII text in the toast.
$raw = (New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding $false))).ReadToEnd()
$hookData = $null
try { $hookData = $raw | ConvertFrom-Json } catch { }
$message = $hookData.message
if (-not $message) { $message = 'Claude Code needs your attention' }
if ($message -match 'permission to use AskUserQuestion') { $message = 'Claude has a question for you' }
$sessionId = $hookData.session_id
$cwd = $hookData.cwd

$dataDir = Join-Path $env:LOCALAPPDATA 'claude-code-windows-kit\toast-notify'
$logoPath = Join-Path $dataDir 'logo.png'
$errorLogPath = Join-Path $dataDir 'error.log'
$appId = 'ClaudeCode.WindowsKit'
$appKey = "HKCU:\Software\Classes\AppUserModelId\$appId"

function Write-ErrorLog {
  param([string]$Text)
  try {
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
    if ((Test-Path $errorLogPath) -and (Get-Item $errorLogPath).Length -gt 128KB) { Move-Item $errorLogPath "$errorLogPath.1" -Force }
    Add-Content -Path $errorLogPath -Value "$(Get-Date -Format o) $Text"
  } catch { }
}

# One line per toast and per click, so "clicking did nothing" can be traced.
# Records only the kind of target and the folder name, never messages.
function Write-Activity {
  param([string]$Text)
  try {
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
    $log = Join-Path $dataDir 'activity.log'
    if ((Test-Path $log) -and (Get-Item $log).Length -gt 128KB) { Move-Item $log "$log.1" -Force }
    Add-Content -Path $log -Value "$(Get-Date -Format o) [$PID] $Text"
  } catch { }
}

# Retries a registry write 3x, 150ms apart, to ride out "marked for deletion" /
# IOException races when several notify.ps1 runs touch the same key at once.
function Invoke-RegistryRetry {
  param([scriptblock]$Action)
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try { & $Action; return } catch {
      if ($attempt -eq 3) { throw }
      Start-Sleep -Milliseconds 150
    }
  }
}

function Find-ClaudeLogo {
  $roots = '.vscode', '.vscode-insiders', '.cursor', '.windsurf' |
    ForEach-Object { Join-Path $env:USERPROFILE "$_\extensions" } |
    Where-Object { Test-Path $_ }
  $candidates = foreach ($root in $roots) {
    Get-ChildItem $root -Directory -Filter 'anthropic.claude-code-*' -ErrorAction SilentlyContinue |
      ForEach-Object { Join-Path $_.FullName 'resources\claude-logo.png' } |
      Where-Object { Test-Path $_ } |
      Get-Item
  }
  $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}

function Find-EditorIcon {
  $roots = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code'),
    (Join-Path $env:ProgramFiles 'Microsoft VS Code'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code Insiders')
  ) | Where-Object { Test-Path $_ }
  foreach ($root in $roots) {
    $ico = Get-ChildItem $root -Recurse -Depth 6 -Filter 'code.ico' -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -like '*\resources\app\resources\win32\code.ico' } |
      Select-Object -First 1
    if ($ico) { return $ico.FullName }
  }
  return $null
}

# Draws one candidate logo (either icon, or both together) and saves it via a
# unique temp file + Move-Item so a concurrently-running notify.ps1 never sees
# a half-written logo.png. Never throws: a corrupt .ico/.png is logged and
# reported as failure so Build-Logo can fall back, not abort the toast.
function Draw-Logo {
  param([string]$EditorPath, [string]$ClaudePath)
  $bmp = $null
  $g = $null
  $editor = $null
  $claude = $null
  try {
    $bmp = New-Object System.Drawing.Bitmap 256, 256
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)

    $editor = if ($EditorPath) { (New-Object System.Drawing.Icon($EditorPath, 256, 256)).ToBitmap() }
    $claude = if ($ClaudePath) { [System.Drawing.Image]::FromFile($ClaudePath) }
    # Both icons stay inside the inscribed circle, since Windows crops the toast logo round.
    if ($editor -and $claude) {
      $g.DrawImage($editor, 46, 46, 104, 104)
      $g.DrawImage($claude, 106, 106, 104, 104)
    } else {
      $g.DrawImage(@($editor, $claude)[[int](-not $editor)], 53, 53, 150, 150)
    }
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
    $tempLogoPath = Join-Path $dataDir "logo.$([Guid]::NewGuid()).tmp.png"
    $bmp.Save($tempLogoPath, [System.Drawing.Imaging.ImageFormat]::Png)
    try {
      Move-Item -LiteralPath $tempLogoPath -Destination $logoPath -Force
    } catch {
      # Another run's Move-Item won the race and logo.png already exists; ours
      # is redundant, not an error.
      Remove-Item -LiteralPath $tempLogoPath -Force -ErrorAction SilentlyContinue
    }
    return $true
  } catch {
    Write-ErrorLog "build-logo: $($_.Exception.Message)"
    return $false
  } finally {
    if ($g) { $g.Dispose() }
    if ($bmp) { $bmp.Dispose() }
    if ($editor) { $editor.Dispose() }
    if ($claude) { $claude.Dispose() }
  }
}

function Build-Logo {
  try {
    Add-Type -AssemblyName System.Drawing
    $claudePath = Find-ClaudeLogo
    $editorPath = Find-EditorIcon
  } catch {
    Write-ErrorLog "build-logo: $($_.Exception.Message)"
    return $false
  }
  if (-not $claudePath -and -not $editorPath) { return $false }

  # Try both icons together first, then fall back to whichever single icon we
  # can still draw alone -- a corrupt .ico or .png must never abort the toast.
  if ($editorPath -and $claudePath -and (Draw-Logo $editorPath $claudePath)) { return $true }
  if ($editorPath -and (Draw-Logo $editorPath $null)) { return $true }
  if ($claudePath -and (Draw-Logo $null $claudePath)) { return $true }
  return $false
}

function Register-App {
  Invoke-RegistryRetry {
    if (-not (Test-Path $appKey)) { New-Item -Path $appKey -Force | Out-Null }
    Set-ItemProperty -Path $appKey -Name DisplayName -Value 'Claude Code'
    if (Test-Path $logoPath) { Set-ItemProperty -Path $appKey -Name IconUri -Value $logoPath }
  }
}

# Maps the extension folder Claude Code's native binary is running from to the
# custom URI scheme (and, in open-session.ps1, the CLI binary) for that editor.
$EditorFolderSchemes = [ordered]@{
  '.vscode'          = 'vscode'
  '.vscode-insiders' = 'vscode-insiders'
  '.cursor'          = 'cursor'
  '.windsurf'        = 'windsurf'
}

# CIM Win32_Process.Name includes the extension (unlike Get-Process's
# ProcessName), used below to recognize an editor process as the terminal
# host for an integrated-terminal session.
$EditorHostProcessNames = [ordered]@{
  'vscode'          = 'Code.exe'
  'vscode-insiders' = 'Code - Insiders.exe'
  'cursor'          = 'Cursor.exe'
  'windsurf'        = 'Windsurf.exe'
}
$TerminalHostProcessName = 'WindowsTerminal.exe'
$ConsoleShellProcessNames = @('powershell.exe', 'pwsh.exe', 'cmd.exe')

# Walks up the process tree from this script (a hook child of claude.exe) to
# work out what should be focused when the toast is clicked. Returns one of:
#   @{ Kind = 'editor' ; Scheme = <name> }           an editor extension session
#   @{ Kind = 'editor-terminal' ; Scheme = <name> }  claude running in an
#                                                      editor's integrated terminal
#   @{ Kind = 'terminal' ; Pid = <pid> }             claude in a standalone
#                                                      console/Windows Terminal
#   @{ Kind = 'none' }                                nothing recognized -> plain toast
function Find-ClaudeHostContext {
  # Test-only override so the click-to-open path can be exercised from a shell
  # whose parent chain is not the VS Code extension's claude.exe (e.g. running
  # this script directly from a terminal while developing/testing it).
  if ($env:CCKIT_TEST_EDITOR) {
    if ($EditorFolderSchemes.Values -contains $env:CCKIT_TEST_EDITOR) {
      return @{ Kind = 'editor'; Scheme = $env:CCKIT_TEST_EDITOR }
    }
    return @{ Kind = 'none' }
  }

  try {
    $procs = @{}
    Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, ExecutablePath -ErrorAction Stop |
      ForEach-Object { $procs[[int]$_.ProcessId] = $_ }

    $currentId = $PID
    $visited = New-Object 'System.Collections.Generic.HashSet[int]'
    while ($procs.ContainsKey($currentId) -and $visited.Add($currentId)) {
      $proc = $procs[$currentId]

      if ($proc.Name -eq 'claude.exe') {
        foreach ($folder in $EditorFolderSchemes.Keys) {
          if ($proc.ExecutablePath -like "*\$folder\extensions\anthropic.claude-code-*\resources\native-binary\claude.exe") {
            return @{ Kind = 'editor'; Scheme = $EditorFolderSchemes[$folder] }
          }
        }
        # A claude.exe ancestor exists but it's not one of the editor
        # extensions (the plain terminal CLI) -> keep walking for the window
        # actually hosting it, instead of giving up here as before.
      }

      # Integrated terminal: claude is running inside an editor's own terminal,
      # so its process tree sits under that editor rather than a standalone
      # console host. (An npm install runs the CLI via node.exe, which never
      # matches 'claude.exe' or any of these names -- it's simply skipped as
      # the walk continues past it to whatever really hosts the window.)
      foreach ($kv in $EditorHostProcessNames.GetEnumerator()) {
        if ($proc.Name -eq $kv.Value) {
          return @{ Kind = 'editor-terminal'; Scheme = $kv.Key }
        }
      }

      # Standalone terminal hosts: Windows Terminal, or a conhost-hosted
      # console shell (powershell/pwsh/cmd). MainWindowHandle non-zero
      # confirms this instance actually owns a visible console window right
      # now, not a headless/background one.
      if ($proc.Name -eq $TerminalHostProcessName) {
        return @{ Kind = 'terminal'; Pid = [int]$currentId }
      }
      if ($ConsoleShellProcessNames -contains $proc.Name) {
        try {
          $shellProc = Get-Process -Id $currentId -ErrorAction Stop
          if ($shellProc.MainWindowHandle -ne [IntPtr]::Zero) {
            return @{ Kind = 'terminal'; Pid = [int]$currentId }
          }
        } catch { }
      }

      if (-not $proc.ParentProcessId) { break }
      $currentId = [int]$proc.ParentProcessId
    }
  } catch { }
  return @{ Kind = 'none' }
}

function Register-ProtocolHandler {
  $openSessionSource = Join-Path $PSScriptRoot 'open-session.ps1'
  if (-not (Test-Path $openSessionSource)) { return }

  New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
  $stableCopy = Join-Path $dataDir 'open-session.ps1'
  $sourceContent = Get-Content -LiteralPath $openSessionSource -Raw
  $upToDate = (Test-Path $stableCopy) -and ((Get-Content -LiteralPath $stableCopy -Raw) -eq $sourceContent)
  if (-not $upToDate) {
    # Temp file + Move-Item so a concurrently-invoked cckit-open: handler never
    # reads a half-written stable copy.
    $tempCopy = Join-Path $dataDir "open-session.$([Guid]::NewGuid()).tmp.ps1"
    Copy-Item -LiteralPath $openSessionSource -Destination $tempCopy -Force
    try {
      Move-Item -LiteralPath $tempCopy -Destination $stableCopy -Force
    } catch {
      Remove-Item -LiteralPath $tempCopy -Force -ErrorAction SilentlyContinue
    }
  }

  # The plugin cache path changes on every update, so the registry always
  # points at this stable LOCALAPPDATA copy rather than $PSScriptRoot.
  # powershell.exe is a console-subsystem exe, so -WindowStyle Hidden still
  # lets a console window flash briefly before it applies. Launching it under
  # conhost --headless (Windows 10 21H2+/11) avoids allocating a visible
  # console at all; fall back to the old command line if conhost isn't there.
  $conhostPath = Join-Path $env:SystemRoot 'System32\conhost.exe'
  $expectedCommand = if (Test-Path $conhostPath) {
    "`"$conhostPath`" --headless powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$stableCopy`" `"%1`""
  } else {
    "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$stableCopy`" `"%1`""
  }
  $protocolKey = 'HKCU:\Software\Classes\cckit-open'
  $commandKey = "$protocolKey\shell\open\command"

  $currentCommand = $null
  if (Test-Path $commandKey) {
    $currentCommand = (Get-Item -Path $commandKey).GetValue('')
  }
  if ($currentCommand -eq $expectedCommand) { return }

  Invoke-RegistryRetry {
    if (-not (Test-Path $protocolKey)) { New-Item -Path $protocolKey -Force | Out-Null }
    Set-ItemProperty -Path $protocolKey -Name '(default)' -Value 'URL:Claude Code Windows Kit'
    Set-ItemProperty -Path $protocolKey -Name 'URL Protocol' -Value ''
    if (-not (Test-Path $commandKey)) { New-Item -Path $commandKey -Force | Out-Null }
    Set-ItemProperty -Path $commandKey -Name '(default)' -Value $expectedCommand
  }
}

# Only attach a click action when the hook gave us enough to resolve a target
# window (and, for an editor extension session, a session id). Nothing
# recognized -> plain toast, no click action.
$hostContext = Find-ClaudeHostContext
$launchUrl = $null
# cwd must be drive-rooted (C:\...); a UNC path here would round-trip through
# open-session.ps1's Get-Item and trigger outbound SMB/NTLM auth, so we don't
# even build a URL for one -- the toast just falls back to plain.
$cwdIsValid = $cwd -and ($cwd -match '^[a-zA-Z]:\\')
if ($cwdIsValid) {
  $encodedCwd = [Uri]::EscapeDataString($cwd)
  switch ($hostContext.Kind) {
    'editor' {
      if ($sessionId -and ($sessionId -match '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z')) {
        $launchUrl = "cckit-open:?editor=$($hostContext.Scheme)&session=$sessionId&cwd=$encodedCwd"
      }
    }
    'editor-terminal' {
      # Claude running in an editor's integrated terminal: click-to-focus that
      # editor window by cwd, same as the editor case, but no session URI.
      $launchUrl = "cckit-open:?host=$($hostContext.Scheme)&cwd=$encodedCwd"
    }
    'terminal' {
      # Standalone console / Windows Terminal: click-to-focus that process's
      # window by pid; no session URI (it isn't an editor session).
      if ($hostContext.Pid) {
        $launchUrl = "cckit-open:?host=terminal&pid=$($hostContext.Pid)&cwd=$encodedCwd"
      }
    }
  }
}

$cwdLeaf = if ($cwd) { Split-Path -Path ([string]$cwd) -Leaf } else { '?' }
Write-Activity "toast in ${cwdLeaf}: host=$($hostContext.Kind)$(if ($hostContext.Scheme) { "/$($hostContext.Scheme)" }) click=$(if ($launchUrl) { 'yes' } else { 'none' })"

try {
  if (-not (Test-Path $logoPath)) { [void](Build-Logo) }
  $needsRegisterApp = -not (Test-Path $appKey)
  if (-not $needsRegisterApp -and (Test-Path $logoPath)) {
    $currentIconUri = (Get-ItemProperty -Path $appKey -Name IconUri -ErrorAction SilentlyContinue).IconUri
    if ($currentIconUri -ne $logoPath) { $needsRegisterApp = $true }
  }
  if ($needsRegisterApp) { Register-App }

  if ($launchUrl) {
    try { Register-ProtocolHandler } catch { Write-ErrorLog "protocol-handler: $($_.Exception.Message)" }
  }

  [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
  [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

  $image = ''
  if (Test-Path $logoPath) {
    $uri = ([Uri]$logoPath).AbsoluteUri
    $image = "<image placement=`"appLogoOverride`" hint-crop=`"circle`" src=`"$uri`"/>"
  }
  $text = [Security.SecurityElement]::Escape($message)
  $toastAttrs = ''
  if ($launchUrl) {
    $escapedLaunch = [Security.SecurityElement]::Escape($launchUrl)
    $toastAttrs = " activationType=`"protocol`" launch=`"$escapedLaunch`""
  }
  $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
  $xml.LoadXml("<toast$toastAttrs><visual><binding template=`"ToastGeneric`"><text>Claude Code</text><text>$text</text>$image</binding></visual></toast>")
  [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
} catch {
  Write-ErrorLog $_.Exception.Message
}
exit 0

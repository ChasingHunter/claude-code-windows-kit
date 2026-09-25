$ErrorActionPreference = 'Stop'

$raw = [Console]::In.ReadToEnd()
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

function Write-ErrorLog {
  param([string]$Text)
  New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
  Add-Content -Path $errorLogPath -Value "$(Get-Date -Format o) $Text"
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

function Build-Logo {
  Add-Type -AssemblyName System.Drawing
  $claudePath = Find-ClaudeLogo
  $editorPath = Find-EditorIcon
  if (-not $claudePath -and -not $editorPath) { return $false }

  $bmp = New-Object System.Drawing.Bitmap 256, 256
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.InterpolationMode = 'HighQualityBicubic'
  $g.PixelOffsetMode = 'HighQuality'
  $g.Clear([System.Drawing.Color]::Transparent)

  $editor = if ($editorPath) { (New-Object System.Drawing.Icon($editorPath, 256, 256)).ToBitmap() }
  $claude = if ($claudePath) { [System.Drawing.Image]::FromFile($claudePath) }
  # Both icons stay inside the inscribed circle, since Windows crops the toast logo round.
  if ($editor -and $claude) {
    $g.DrawImage($editor, 46, 46, 104, 104)
    $g.DrawImage($claude, 106, 106, 104, 104)
  } else {
    $g.DrawImage(@($editor, $claude)[[int](-not $editor)], 53, 53, 150, 150)
  }
  $g.Dispose()
  New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
  $bmp.Save($logoPath, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  if ($editor) { $editor.Dispose() }
  if ($claude) { $claude.Dispose() }
  return $true
}

function Register-App {
  $key = "HKCU:\Software\Classes\AppUserModelId\$appId"
  if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
  Set-ItemProperty -Path $key -Name DisplayName -Value 'Claude Code'
  if (Test-Path $logoPath) { Set-ItemProperty -Path $key -Name IconUri -Value $logoPath }
}

# Maps the extension folder Claude Code's native binary is running from to the
# custom URI scheme (and, in open-session.ps1, the CLI binary) for that editor.
$EditorFolderSchemes = [ordered]@{
  '.vscode'          = 'vscode'
  '.vscode-insiders' = 'vscode-insiders'
  '.cursor'          = 'cursor'
  '.windsurf'        = 'windsurf'
}

function Find-EditorContext {
  # Test-only override so the click-to-open path can be exercised from a shell
  # whose parent chain is not the VS Code extension's claude.exe (e.g. running
  # this script directly from a terminal while developing/testing it).
  if ($env:CCKIT_TEST_EDITOR) {
    if ($EditorFolderSchemes.Values -contains $env:CCKIT_TEST_EDITOR) { return $env:CCKIT_TEST_EDITOR }
    return $null
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
            return $EditorFolderSchemes[$folder]
          }
        }
        # A claude.exe ancestor exists but it's not one of the editor extensions
        # (e.g. the plain terminal CLI) -> no click action.
        return $null
      }
      if (-not $proc.ParentProcessId) { break }
      $currentId = [int]$proc.ParentProcessId
    }
  } catch { }
  return $null
}

function Register-ProtocolHandler {
  $openSessionSource = Join-Path $PSScriptRoot 'open-session.ps1'
  if (-not (Test-Path $openSessionSource)) { return }

  New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
  $stableCopy = Join-Path $dataDir 'open-session.ps1'
  $sourceContent = Get-Content -LiteralPath $openSessionSource -Raw
  $upToDate = (Test-Path $stableCopy) -and ((Get-Content -LiteralPath $stableCopy -Raw) -eq $sourceContent)
  if (-not $upToDate) {
    Copy-Item -LiteralPath $openSessionSource -Destination $stableCopy -Force
  }

  # The plugin cache path changes on every update, so the registry always
  # points at this stable LOCALAPPDATA copy rather than $PSScriptRoot.
  $expectedCommand = "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$stableCopy`" `"%1`""
  $protocolKey = 'HKCU:\Software\Classes\cckit-open'
  $commandKey = "$protocolKey\shell\open\command"

  $currentCommand = $null
  if (Test-Path $commandKey) {
    $currentCommand = (Get-Item -Path $commandKey).GetValue('')
  }
  if ($currentCommand -eq $expectedCommand) { return }

  if (-not (Test-Path $protocolKey)) { New-Item -Path $protocolKey -Force | Out-Null }
  Set-ItemProperty -Path $protocolKey -Name '(default)' -Value 'URL:Claude Code Windows Kit'
  Set-ItemProperty -Path $protocolKey -Name 'URL Protocol' -Value ''
  if (-not (Test-Path $commandKey)) { New-Item -Path $commandKey -Force | Out-Null }
  Set-ItemProperty -Path $commandKey -Name '(default)' -Value $expectedCommand
}

# Only attach a click action when we're inside a supported editor extension and
# the hook gave us enough to resolve a window + session. Terminal sessions (no
# claude.exe editor ancestor) always fall through to a plain toast.
$editorScheme = Find-EditorContext
$launchUrl = $null
if ($editorScheme -and $sessionId -and $cwd -and ($sessionId -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')) {
  $encodedCwd = [Uri]::EscapeDataString($cwd)
  $launchUrl = "cckit-open:?editor=$editorScheme&session=$sessionId&cwd=$encodedCwd"
}

try {
  if (-not (Test-Path $logoPath)) { [void](Build-Logo) }
  if (-not (Test-Path "HKCU:\Software\Classes\AppUserModelId\$appId")) { Register-App }

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

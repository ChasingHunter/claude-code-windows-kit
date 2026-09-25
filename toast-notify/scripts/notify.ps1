$ErrorActionPreference = 'Stop'

$raw = [Console]::In.ReadToEnd()
$message = $null
try { $message = ($raw | ConvertFrom-Json).message } catch { }
if (-not $message) { $message = 'Claude Code needs your attention' }
if ($message -match 'permission to use AskUserQuestion') { $message = 'Claude has a question for you' }

$dataDir = Join-Path $env:LOCALAPPDATA 'claude-code-windows-kit\toast-notify'
$logoPath = Join-Path $dataDir 'logo.png'
$appId = 'ClaudeCode.WindowsKit'

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

try {
  if (-not (Test-Path $logoPath)) { [void](Build-Logo) }
  if (-not (Test-Path "HKCU:\Software\Classes\AppUserModelId\$appId")) { Register-App }

  [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
  [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

  $image = ''
  if (Test-Path $logoPath) {
    $uri = ([Uri]$logoPath).AbsoluteUri
    $image = "<image placement=`"appLogoOverride`" hint-crop=`"circle`" src=`"$uri`"/>"
  }
  $text = [Security.SecurityElement]::Escape($message)
  $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
  $xml.LoadXml("<toast><visual><binding template=`"ToastGeneric`"><text>Claude Code</text><text>$text</text>$image</binding></visual></toast>")
  [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
} catch {
  New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
  Add-Content -Path (Join-Path $dataDir 'error.log') -Value "$(Get-Date -Format o) $($_.Exception.Message)"
}
exit 0

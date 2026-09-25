# Handler for the cckit-open: URL protocol. Registered per-user (no admin) by
# notify.ps1 so clicking a toast opens the right editor window on the right
# session. Windows invokes this as:
#   open-session.ps1 "cckit-open:?editor=<name>&session=<uuid>&cwd=<encoded path>"
#
# The whole URL arrives as a single argument ($args[0]). ANY application on the
# machine (including a web page, via the browser's protocol handler) can invoke
# a registered URL protocol, so every field below is treated as hostile input:
# strict allowlists/regex/existence checks, no string-built shell commands, no
# Invoke-Expression. Process launches use Start-Process with argument arrays,
# never a concatenated command string.

$ErrorActionPreference = 'Stop'

$dataDir = Join-Path $env:LOCALAPPDATA 'claude-code-windows-kit\toast-notify'
$stableCopy = Join-Path $dataDir 'open-session.ps1'
$protocolKey = 'HKCU:\Software\Classes\cckit-open'
$errorLogPath = Join-Path $dataDir 'error.log'
$pluginKey = 'toast-notify@claude-code-windows-kit'

function Write-ErrorLog {
  param([string]$Text)
  try {
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
    Add-Content -Path $errorLogPath -Value "$(Get-Date -Format o) $Text"
  } catch { }
}

# Test-only override: points the installed-plugins check at a temp file instead
# of the real %USERPROFILE%\.claude\plugins\installed_plugins.json, so the
# self-clean path can be exercised without touching the real one.
$installedPluginsPath = if ($env:CCKIT_TEST_INSTALLED_PLUGINS_PATH) {
  $env:CCKIT_TEST_INSTALLED_PLUGINS_PATH
} else {
  Join-Path $env:USERPROFILE '.claude\plugins\installed_plugins.json'
}

# Returns $true if the plugin is (or might still be) installed, $false only when
# we positively confirmed it is not. Any doubt (missing/unreadable/unexpected
# shape) errs toward $true so we never self-delete on a guess.
function Test-PluginInstalled {
  if (-not (Test-Path $installedPluginsPath)) { return $true }
  try {
    $data = Get-Content -LiteralPath $installedPluginsPath -Raw | ConvertFrom-Json
  } catch {
    return $true
  }
  if (-not $data -or -not $data.plugins) { return $true }
  $prop = $data.plugins.PSObject.Properties | Where-Object { $_.Name -eq $pluginKey } | Select-Object -First 1
  if (-not $prop) { return $false }
  $entries = @($prop.Value)
  return $entries.Count -gt 0
}

function Remove-ProtocolHandler {
  try { if (Test-Path $protocolKey) { Remove-Item -Path $protocolKey -Recurse -Force } } catch { }
  try { if (Test-Path $stableCopy) { Remove-Item -LiteralPath $stableCopy -Force } } catch { }
}

# editor query value -> URI scheme + CLI binary name.
$EditorInfo = @{
  'vscode'          = @{ Scheme = 'vscode';          Cli = 'code' }
  'vscode-insiders' = @{ Scheme = 'vscode-insiders'; Cli = 'code-insiders' }
  'cursor'          = @{ Scheme = 'cursor';           Cli = 'cursor' }
  'windsurf'        = @{ Scheme = 'windsurf';         Cli = 'windsurf' }
}

function Find-Cli {
  param([string]$Name)
  $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd) { return $cmd.Source }

  $candidates = switch ($Name) {
    'code' { @(
      (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
      (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd')
    ) }
    'code-insiders' { @(
      (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code Insiders\bin\code-insiders.cmd'),
      (Join-Path $env:ProgramFiles 'Microsoft VS Code Insiders\bin\code-insiders.cmd')
    ) }
    'cursor' { @(
      (Join-Path $env:LOCALAPPDATA 'Programs\cursor\bin\cursor.cmd'),
      (Join-Path $env:ProgramFiles 'cursor\bin\cursor.cmd')
    ) }
    'windsurf' { @(
      (Join-Path $env:LOCALAPPDATA 'Programs\Windsurf\bin\windsurf.cmd'),
      (Join-Path $env:ProgramFiles 'Windsurf\bin\windsurf.cmd')
    ) }
    default { @() }
  }
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
  return $null
}

try {
  if (-not (Test-PluginInstalled)) {
    Remove-ProtocolHandler
    exit 0
  }

  $url = $args[0]
  if (-not $url) { exit 0 }

  $queryStart = $url.IndexOf('?')
  if ($queryStart -lt 0) { exit 0 }
  $query = $url.Substring($queryStart + 1)

  $params = @{}
  foreach ($pair in $query -split '&') {
    if (-not $pair) { continue }
    $kv = $pair.Split('=', 2)
    if (-not $kv[0]) { continue }
    $value = if ($kv.Length -gt 1) { [Uri]::UnescapeDataString($kv[1]) } else { '' }
    $params[$kv[0]] = $value
  }

  $editor = $params['editor']
  $session = $params['session']
  $cwd = $params['cwd']

  if (-not $editor -or -not $EditorInfo.ContainsKey($editor)) { exit 0 }
  if (-not $session -or $session -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { exit 0 }
  if (-not $cwd) { exit 0 }

  # Must be a drive-rooted (C:\...) or UNC (\\server\share\...) absolute path.
  # Path]::IsPathRooted alone also accepts drive-relative "\foo", which is not
  # what we want here.
  $isAbsolute = ($cwd -match '^[a-zA-Z]:\\') -or ($cwd -match '^\\\\')
  if (-not $isAbsolute) { exit 0 }

  $dir = $null
  try { $dir = Get-Item -LiteralPath $cwd -ErrorAction Stop } catch { exit 0 }
  if (-not $dir.PSIsContainer) { exit 0 }
  $cwd = $dir.FullName

  $info = $EditorInfo[$editor]
  $cliPath = Find-Cli $info.Cli

  if ($cliPath) {
    # code/cursor/windsurf CLIs reuse (and focus) an existing window for this folder.
    # code.cmd runs through cmd.exe, and Start-Process's -ArgumentList joins
    # elements with spaces without quoting them, so an unquoted path with a
    # space or an "&" would split into multiple/garbled arguments. Windows
    # paths can never contain '"', so quoting like this is always safe.
    Start-Process -FilePath $cliPath -ArgumentList ('"' + $cwd + '"') -WindowStyle Hidden
  } else {
    $fileUrl = "$($info.Scheme)://file/$($cwd -replace '\\', '/')"
    Start-Process -FilePath $fileUrl
  }

  # Give the window time to come to the front before the session URI targets
  # "the most recently focused window".
  Start-Sleep -Milliseconds 1500

  $sessionUrl = "$($info.Scheme)://anthropic.claude-code/open?session=$session"
  Start-Process -FilePath $sessionUrl
} catch {
  Write-ErrorLog $_.Exception.Message
}
exit 0

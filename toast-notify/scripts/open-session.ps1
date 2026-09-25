# Handler for the cckit-open: URL protocol. Registered per-user (no admin) by
# notify.ps1 so clicking a toast brings up the right window for the right
# session. Windows invokes this as one of:
#   open-session.ps1 "cckit-open:?editor=<name>&session=<uuid>&cwd=<encoded path>"
#   open-session.ps1 "cckit-open:?host=terminal&pid=<host pid>&cwd=<encoded path>"
#   open-session.ps1 "cckit-open:?host=<editor name>&cwd=<encoded path>"
#
# The first shape (an editor's own extension session) focuses the matching
# editor window, or launches one if none is found, then fires the session URI.
# The other two (added for terminal / integrated-terminal sessions, which have
# no session URI to fall back on) only ever focus an existing window -- if
# nothing matches, they do nothing.
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

# editor query value -> URI scheme, CLI binary name, the window process(es) to
# search when focusing an existing window, and the "AppName" suffix VS-Code-
# family windows put at the end of their title (see Find-EditorWindow).
$EditorInfo = @{
  'vscode'          = @{ Scheme = 'vscode';          Cli = 'code';          ProcessNames = @('Code');            AppName = 'Visual Studio Code' }
  'vscode-insiders' = @{ Scheme = 'vscode-insiders'; Cli = 'code-insiders'; ProcessNames = @('Code - Insiders'); AppName = 'Visual Studio Code - Insiders' }
  'cursor'          = @{ Scheme = 'cursor';           Cli = 'cursor';       ProcessNames = @('Cursor');          AppName = 'Cursor' }
  'windsurf'        = @{ Scheme = 'windsurf';         Cli = 'windsurf';     ProcessNames = @('Windsurf');        AppName = 'Windsurf' }
}

# Processes allowed as a terminal focus target for host=terminal. A hostile
# page can pass any pid, so open-session.ps1 must independently confirm the
# pid names one of these before ever touching it -- see the host=terminal
# branch below.
$TerminalHostProcessNames = @('WindowsTerminal')
$ConsoleShellProcessNames = @('powershell', 'pwsh', 'cmd')

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public class CckitWin {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    public static List<IntPtr> TopWindows() {
        var list = new List<IntPtr>();
        EnumWindows((h, l) => { list.Add(h); return true; }, IntPtr.Zero);
        return list;
    }
    public static string GetTitle(IntPtr hWnd) {
        int len = GetWindowTextLength(hWnd);
        if (len == 0) return "";
        var sb = new StringBuilder(len + 1);
        GetWindowText(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }
}
'@

# Same drive-rooted-only + existence checks the original code applied to cwd,
# now shared by every branch that needs a validated cwd (see the big comment
# at the original call site, kept below): a UNC path here would make Windows
# silently attempt outbound SMB/NTLM auth to whatever host is named, so it is
# rejected before any filesystem call touches it. Returns $null on anything
# invalid; otherwise the canonicalized, existing directory path.
function Get-ValidatedCwd {
  param([string]$CwdText)
  if (-not $CwdText) { return $null }
  # Must be drive-rooted (C:\...) ONLY. [Path]::IsPathRooted alone also accepts
  # drive-relative "\foo" and UNC "\\server\share", neither of which we want.
  if ($CwdText -notmatch '^[a-zA-Z]:\\') { return $null }
  $dir = $null
  try { $dir = Get-Item -LiteralPath $CwdText -ErrorAction Stop } catch { return $null }
  if (-not $dir.PSIsContainer) { return $null }
  return $dir.FullName
}

# pid must be a positive 32-bit-range integer before it is ever passed to
# Get-Process -- a hostile page can put anything after pid=.
function Test-ValidPid {
  param([string]$PidText)
  if (-not $PidText) { return $false }
  if ($PidText -notmatch '^\d{1,10}$') { return $false }
  $value = [int64]$PidText
  return ($value -ge 1 -and $value -le 2147483648)
}

# Candidate window-title root names for $Cwd, most specific first: the leaf
# name of $Cwd, then each ancestor directory, so a session whose cwd is a
# subfolder of the actually-open workspace still matches. At each directory
# level, a sibling *.code-workspace file's name is checked first (VS Code
# titles a workspace window after the .code-workspace file, not the folder),
# since resolving that from live window state isn't reliable -- see the
# storage.json finding in the diagnosis notes.
function Get-CandidateRootNames {
  param([string]$Cwd)
  $names = New-Object System.Collections.Generic.List[string]
  $dir = $null
  try { $dir = Get-Item -LiteralPath $Cwd -ErrorAction Stop } catch { return $names }
  while ($dir) {
    try {
      Get-ChildItem -LiteralPath $dir.FullName -Filter '*.code-workspace' -File -ErrorAction SilentlyContinue |
        ForEach-Object { $names.Add([System.IO.Path]::GetFileNameWithoutExtension($_.Name)) }
    } catch { }
    if ($dir.Name -and ($dir.Name -notmatch '^[a-zA-Z]:\\?$')) { $names.Add($dir.Name) }
    $dir = $dir.Parent
  }
  return $names
}

# Finds a visible top-level window belonging to one of $ProcessNames whose
# title matches one of $RootNames, most specific root first. VS-Code-family
# windows title themselves "<tab/file> - <root> - <AppName>" (or just
# "<root> - <AppName>" with nothing open), so a title containing " - <root> - "
# or ending in "<root> - <AppName>" identifies the window for that root,
# case-insensitively (the reported bug includes a drive-letter case mismatch
# between the hook's cwd and the window's own folder path). Ties (several
# windows matching the same root) go to the first hit in enumeration order,
# which is Z-order top-to-bottom, i.e. the most recently active. Returns
# [IntPtr]::Zero if nothing matches.
function Find-EditorWindow {
  param([string[]]$ProcessNames, [string]$AppNameHint, [System.Collections.Generic.List[string]]$RootNames)
  if (-not $RootNames -or $RootNames.Count -eq 0) { return [IntPtr]::Zero }

  $windows = New-Object System.Collections.Generic.List[object]
  foreach ($hWnd in [CckitWin]::TopWindows()) {
    if (-not [CckitWin]::IsWindowVisible($hWnd)) { continue }
    $title = [CckitWin]::GetTitle($hWnd)
    if (-not $title) { continue }
    [uint32]$procId = 0
    [void][CckitWin]::GetWindowThreadProcessId($hWnd, [ref]$procId)
    $proc = $null
    try { $proc = Get-Process -Id $procId -ErrorAction Stop } catch { continue }
    if ($ProcessNames -notcontains $proc.ProcessName) { continue }
    $windows.Add([pscustomobject]@{ Hwnd = $hWnd; Title = $title })
  }
  if ($windows.Count -eq 0) { return [IntPtr]::Zero }

  foreach ($root in $RootNames) {
    $escapedRoot = [regex]::Escape($root)
    $patternContains = ' - ' + $escapedRoot + ' - '
    $patternEnds = [regex]::Escape("$root - $AppNameHint") + '$'
    foreach ($w in $windows) {
      if ($w.Title -imatch $patternContains -or $w.Title -imatch $patternEnds) { return $w.Hwnd }
    }
  }
  return [IntPtr]::Zero
}

# Brings $Hwnd to the foreground from this background process, verifying with
# GetForegroundWindow at each step rather than trusting the return value alone.
function Set-ForegroundWindowRobust {
  param([IntPtr]$Hwnd)
  if ($Hwnd -eq [IntPtr]::Zero) { return $false }

  if ([CckitWin]::IsIconic($Hwnd)) { [void][CckitWin]::ShowWindow($Hwnd, 9) } # SW_RESTORE
  [void][CckitWin]::SetForegroundWindow($Hwnd)
  Start-Sleep -Milliseconds 50
  if ([CckitWin]::GetForegroundWindow() -eq $Hwnd) { return $true }

  # Standard workaround for Windows' foreground-lock: attach our input thread
  # to the current foreground window's thread, which is allowed to change
  # focus, then retry through it.
  $fgWnd = [CckitWin]::GetForegroundWindow()
  [uint32]$fgProcId = 0
  $fgThreadId = [CckitWin]::GetWindowThreadProcessId($fgWnd, [ref]$fgProcId)
  $curThreadId = [CckitWin]::GetCurrentThreadId()
  if ($fgThreadId -ne 0 -and $fgThreadId -ne $curThreadId) {
    [void][CckitWin]::AttachThreadInput($curThreadId, $fgThreadId, $true)
    try {
      [void][CckitWin]::ShowWindow($Hwnd, 9)
      [void][CckitWin]::SetForegroundWindow($Hwnd)
    } finally {
      [void][CckitWin]::AttachThreadInput($curThreadId, $fgThreadId, $false)
    }
    Start-Sleep -Milliseconds 50
    if ([CckitWin]::GetForegroundWindow() -eq $Hwnd) { return $true }
  }

  # Last resort: a synthetic ALT tap defeats the foreground-lock timeout
  # heuristic (Windows allows the caller through right after simulated input).
  [CckitWin]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)  # ALT down
  [CckitWin]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)  # ALT up (KEYEVENTF_KEYUP)
  [void][CckitWin]::SetForegroundWindow($Hwnd)
  Start-Sleep -Milliseconds 50
  return ([CckitWin]::GetForegroundWindow() -eq $Hwnd)
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

  $hostType = $params['host']

  if ($hostType) {
    # --- Problem 2: terminal / integrated-terminal sessions. No session URI
    # exists for these, so all we ever do is try to focus an existing window;
    # never fall back to launching anything.
    if ($hostType -eq 'terminal') {
      $cwd = Get-ValidatedCwd $params['cwd']
      if (-not $cwd) { exit 0 }
      if (-not (Test-ValidPid $params['pid'])) { exit 0 }
      $targetPid = [int]$params['pid']

      # A hostile page can pass any pid: confirm the process still exists AND
      # that its name is one we allow focusing (WindowsTerminal, or a console
      # shell -- npm-installed claude runs under node.exe, so the ancestor
      # notify.ps1 found and reported here is the shell/terminal, not claude).
      $proc = $null
      try { $proc = Get-Process -Id $targetPid -ErrorAction Stop } catch { exit 0 }
      $isAllowedHost = ($TerminalHostProcessNames -contains $proc.ProcessName) -or
        ($ConsoleShellProcessNames -contains $proc.ProcessName)
      if (-not $isAllowedHost) { exit 0 }

      $proc.Refresh()
      $targetHwnd = $proc.MainWindowHandle
      # NOTE: with several windows sharing one WindowsTerminal.exe process, this
      # picks whichever MainWindowHandle .NET reports for that pid -- it cannot
      # target a specific tab, and may focus the wrong Windows Terminal window.
      if ($targetHwnd -ne [IntPtr]::Zero) { [void](Set-ForegroundWindowRobust $targetHwnd) }
      exit 0
    }

    if ($EditorInfo.ContainsKey($hostType)) {
      # Editor integrated terminal: same window lookup as the editor+session
      # path below, but there is no session to open and no `code` fallback --
      # if no window matches, do nothing.
      $cwd = Get-ValidatedCwd $params['cwd']
      if (-not $cwd) { exit 0 }
      $info = $EditorInfo[$hostType]
      $roots = Get-CandidateRootNames -Cwd $cwd
      $targetHwnd = Find-EditorWindow -ProcessNames $info.ProcessNames -AppNameHint $info.AppName -RootNames $roots
      if ($targetHwnd -ne [IntPtr]::Zero) { [void](Set-ForegroundWindowRobust $targetHwnd) }
      exit 0
    }

    # Unrecognized host -> no action.
    exit 0
  }

  # --- Problem 1: an editor extension session (cckit-open:?editor=&session=&cwd=).
  $editor = $params['editor']
  $session = $params['session']

  if (-not $editor -or -not $EditorInfo.ContainsKey($editor)) { exit 0 }
  if (-not $session -or $session -notmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z') { exit 0 }
  $cwd = Get-ValidatedCwd $params['cwd']
  if (-not $cwd) { exit 0 }

  $info = $EditorInfo[$editor]

  # Focus an existing window for this cwd first; only launch/create one if
  # none is found. This is what actually fixes "click opens a new window":
  # the old code always ran `code "<cwd>"` and hoped it would reuse the right
  # window within the fixed sleep below, which fails whenever cwd is a
  # subfolder of the open workspace root, or its drive letter differs in case
  # from how the window's own folder was opened -- both confirmed causes (see
  # diagnosis notes). Find-EditorWindow matches by live window title instead
  # of relying on that CLI heuristic, walking cwd's ancestors and comparing
  # case-insensitively.
  $roots = Get-CandidateRootNames -Cwd $cwd
  $targetHwnd = Find-EditorWindow -ProcessNames $info.ProcessNames -AppNameHint $info.AppName -RootNames $roots

  if ($targetHwnd -ne [IntPtr]::Zero) {
    [void](Set-ForegroundWindowRobust $targetHwnd)
    Start-Sleep -Milliseconds 400
  } else {
    $cliPath = Find-Cli $info.Cli

    if ($cliPath) {
      # code/cursor/windsurf CLIs reuse (and focus) an existing window for this folder.
      # code.cmd runs through cmd.exe, and Start-Process's -ArgumentList joins
      # elements with spaces without quoting them, so an unquoted path with a
      # space or an "&" would split into multiple/garbled arguments. Windows
      # paths can never contain '"', so quoting like this is always safe -- except
      # a path ending in '\' (e.g. a drive root "C:\"), where argv parsing reads
      # \" as an escaped quote and swallows the close quote; double any trailing
      # backslashes first so "C:\\" parses back as C:\.
      $argCwd = $cwd
      if ($argCwd -match '\\+$') { $argCwd += $matches[0] }
      Start-Process -FilePath $cliPath -ArgumentList ('"' + $argCwd + '"') -WindowStyle Hidden
    } else {
      $fileUrl = "$($info.Scheme)://file/$($cwd -replace '\\', '/')"
      Start-Process -FilePath $fileUrl
    }

    # Give the window time to come to the front before the session URI targets
    # "the most recently focused window". Only needed on this fallback path --
    # the focus above already confirmed the window is foreground.
    Start-Sleep -Milliseconds 1500
  }

  $sessionUrl = "$($info.Scheme)://anthropic.claude-code/open?session=$session"
  Start-Process -FilePath $sessionUrl
} catch {
  Write-ErrorLog $_.Exception.Message
}
exit 0

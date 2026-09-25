# The widget's own background `claude -p /usage` checks start sessions too; don't relaunch from those.
if ($env:USAGE_WIDGET_POLL) { exit 0 }

$source = Join-Path $PSScriptRoot '..\src\ClaudeUsageWidget.cs'
$dataDir = Join-Path $env:LOCALAPPDATA 'claude-code-windows-kit\usage-widget'
$exe = Join-Path $dataDir 'ClaudeUsageWidget.exe'
$stampFile = Join-Path $dataDir 'source.sha256'

try {
  New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
  $hash = (Get-FileHash $source -Algorithm SHA256).Hash
  $built = Get-Content $stampFile -ErrorAction SilentlyContinue

  if (-not (Test-Path $exe) -or $built -ne $hash) {
    Get-Process ClaudeUsageWidget -ErrorAction SilentlyContinue |
      Where-Object { $_.Path -eq $exe } |
      Stop-Process -Force
    Start-Sleep -Milliseconds 500

    $csc = @(
      (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
      (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $csc) { throw 'C# compiler from .NET Framework 4 not found' }

    $output = & $csc /nologo /target:winexe /optimize+ "/out:$exe" /r:System.Windows.Forms.dll /r:System.Drawing.dll $source 2>&1
    if ($LASTEXITCODE -ne 0) { throw "compile failed: $output" }
    Set-Content -Path $stampFile -Value $hash
  }

  Start-Process $exe
} catch {
  Add-Content -Path (Join-Path $dataDir 'error.log') -Value "$(Get-Date -Format o) $($_.Exception.Message)"
}
exit 0

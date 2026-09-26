# usage-widget

A small always-on-top Windows widget showing your Claude usage limits:

- **Session**: the 5-hour window, with its reset time
- **Weekly**: the 7-day window, with its reset time

Bars change color by how much is used: green under 50%, yellow 50–74%, orange 75–89%, red 90%+.

## Behavior

- Opens when you start or resume a chat, or run `/clear`. Only one copy ever runs.
- **−** minimizes to the taskbar, **×** closes it until your next new chat. Drag it anywhere.
- Refreshes every 10 minutes, and only while Claude Code is running (the
  native `claude.exe` or an npm install running under Node). If a refresh
  comes back without numbers, which can happen right after startup, it
  retries after a minute, up to 3 times.
- On opening it shows the last saved numbers until the first refresh lands;
  the status line says "· refreshing" meanwhile.
- "updated Xm ago" turns orange if the data is more than 25 minutes old.
- Each refresh's outcome (ok, no numbers, timed out) is written to
  `activity.log` next to the compiled widget, capped at 128 KB.

## How it works

A `SessionStart` hook runs [`scripts/launch.ps1`](scripts/launch.ps1), which compiles [`src/ClaudeUsageWidget.cs`](src/ClaudeUsageWidget.cs) with the C# compiler built into Windows (first run, or after a plugin update) and starts it. The compiled program lives in `%LOCALAPPDATA%\claude-code-windows-kit\usage-widget\`.

The widget gets its numbers by running `claude -p /usage`, the same `/usage` command you can type in Claude Code. It finds `claude` on your PATH, or the copy bundled with the VS Code / Cursor / Windsurf extension.

## Resource use

About 25 MB of RAM for the widget. Each refresh briefly starts the Claude CLI (a few seconds), and refreshes are skipped when Claude isn't running.

## For other plugin authors

Each background check runs `claude -p /usage` as a real CLI invocation, which also fires other plugins' `SessionStart` hooks — this is harmless, but if your plugin should skip it, check for the `USAGE_WIDGET_POLL=1` environment variable and exit early.

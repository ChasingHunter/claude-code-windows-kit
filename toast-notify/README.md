# toast-notify

Native Windows toast notification whenever Claude Code:

- needs your permission to use a tool
- asks you a question
- has been waiting for your input

The toast shows as **Claude Code** with an icon combining VS Code and Claude, built on first use from the icons already on your PC. Windows' own notification sound plays with it.

## How it works

A `Notification` hook runs [`scripts/notify.ps1`](scripts/notify.ps1), which:

1. Reads the notification message Claude Code sends on stdin.
2. On first run, builds the icon into `%LOCALAPPDATA%\claude-code-windows-kit\toast-notify\logo.png` and registers the app name "Claude Code" under `HKCU` (no admin needed).
3. Shows the toast through the Windows notification API.

Errors are written to `%LOCALAPPDATA%\claude-code-windows-kit\toast-notify\error.log` instead of interrupting Claude.

## Click to open

If Claude Code is running inside the VS Code extension (VS Code, Insiders, Cursor, or Windsurf) and the notification has a session to open, clicking the toast focuses that editor window and jumps straight to the session — like clicking a Slack or Teams notification. Terminal sessions still get a plain toast; there's no window for a click to open.

To do this, the first click-able toast registers a per-user, click-to-open URL type (`cckit-open:`) under `HKCU\Software\Classes`, pointing at a copy of the handler script in `%LOCALAPPDATA%\claude-code-windows-kit\toast-notify\`. It only ever opens the editor window and session a toast was built for — it can't be reused for anything else. It checks on every click whether `toast-notify` is still installed and quietly removes itself the next time it's invoked after you uninstall the plugin, so nothing lingers.

## Customize

- Rebuild the icon (e.g. after installing VS Code): delete `logo.png` from the folder above.
- Turn toasts off without uninstalling: `/plugin disable toast-notify@claude-code-windows-kit`.
- Windows Focus / Do Not Disturb hides toasts like any other app's.

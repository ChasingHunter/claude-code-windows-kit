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

## Customize

- Rebuild the icon (e.g. after installing VS Code): delete `logo.png` from the folder above.
- Turn toasts off without uninstalling: `/plugin disable toast-notify@claude-code-windows-kit`.
- Windows Focus / Do Not Disturb hides toasts like any other app's.

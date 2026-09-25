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

Clicking the toast brings up the window Claude Code is running in, like clicking a Slack or Teams notification:

- **Inside the VS Code extension** (VS Code, Insiders, Cursor, or Windsurf), it focuses that editor window and jumps straight to the session. If the window is no longer open, it opens one.
- **In a terminal** — Windows Terminal, a classic console window, or an editor's integrated terminal — it just focuses that window. There's no session to jump to from a terminal, so nothing opens if the window is already gone.

Focusing looks for the right window by title (matching the session's folder name, or its containing folder if you're a few levels below the open workspace) rather than trusting the editor CLI to reuse the right window, which is what used to occasionally pop a second copy of the window instead of focusing the existing one.

With several windows sharing one Windows Terminal process, focus-by-window can land on the wrong Windows Terminal window, and it can't pick a specific tab within one — Windows doesn't expose enough to target a tab from outside the app.

To do this, the first click-able toast registers a per-user, click-to-open URL type (`cckit-open:`) under `HKCU\Software\Classes`, pointing at a copy of the handler script in `%LOCALAPPDATA%\claude-code-windows-kit\toast-notify\`. It only ever focuses (or, for an editor session, opens) the window and session a toast was built for — it can't be reused for anything else. It checks on every click whether `toast-notify` is still installed and quietly removes itself the next time it's invoked after you uninstall the plugin, so nothing lingers.

## Troubleshooting

- **First click shows a VS Code prompt** asking to allow an external app to open the Claude Code extension's URI. That's VS Code's own security prompt for `cckit-open:`, not something this plugin can suppress — tick **"Do not ask me again for this extension"** once and it won't come back.
- **After updating the plugin**, the click handler's registry entry only refreshes itself the next time a toast fires. If clicking right after an update doesn't behave like the new version, wait for (or trigger) one more notification, or restart/reload the Claude Code session.

## Customize

- Rebuild the icon (e.g. after installing VS Code): delete `logo.png` from the folder above.
- Turn toasts off without uninstalling: `/plugin disable toast-notify@claude-code-windows-kit`.
- Windows Focus / Do Not Disturb hides toasts like any other app's.

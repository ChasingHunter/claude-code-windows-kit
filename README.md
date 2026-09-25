# claude-code-windows-kit

Small Windows quality-of-life plugins for [Claude Code](https://code.claude.com). Each plugin lives in its own folder and installs on its own.

| Plugin | What it does |
| --- | --- |
| [`toast-notify`](toast-notify/) | Native Windows toast (bottom-right) whenever Claude Code needs your permission or is waiting for input, even when you're tabbed out. |
| [`usage-widget`](usage-widget/) | Small always-on-top widget showing your **Session** and **Weekly** usage limits, color-coded green → yellow → orange → red. |

Works with Claude Code in the terminal and in the VS Code extension (also Cursor / Windsurf / VS Code Insiders).

## Install

Inside Claude Code, run:

```
/plugin marketplace add ChasingHunter/claude-code-windows-kit
/plugin install toast-notify@claude-code-windows-kit
/plugin install usage-widget@claude-code-windows-kit
```

Install one or both. Start a new chat afterwards so the hooks load.

## Requirements

- Windows 10 or 11
- A recent Claude Code version
- `usage-widget` needs a Claude Pro/Max subscription login (API-key logins have no session/weekly limits to show)

Nothing else to install: the plugins use PowerShell and the .NET Framework that ship with Windows.

## Uninstall

```
/plugin uninstall toast-notify@claude-code-windows-kit
/plugin uninstall usage-widget@claude-code-windows-kit
```

Optional cleanup of generated files: delete `%LOCALAPPDATA%\claude-code-windows-kit` and the registry keys `HKCU\Software\Classes\AppUserModelId\ClaudeCode.WindowsKit` and `HKCU\Software\Classes\cckit-open`. One-line version, paste into PowerShell:

```powershell
Remove-Item "$env:LOCALAPPDATA\claude-code-windows-kit" -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item 'HKCU:\Software\Classes\AppUserModelId\ClaudeCode.WindowsKit' -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item 'HKCU:\Software\Classes\cckit-open' -Recurse -Force -ErrorAction SilentlyContinue
```

## Privacy

Everything runs locally. `usage-widget` reads your limits by running Claude Code's own `claude -p /usage` command; no tokens or credentials are read by these scripts, and nothing is sent anywhere else.

## Trademarks

No third-party logos are included in this repo. `toast-notify` builds its icon on your machine from the VS Code and Claude icons already installed there.

## License

MIT

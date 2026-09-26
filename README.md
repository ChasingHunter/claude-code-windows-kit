# claude-code-windows-kit

Small Windows quality-of-life plugins for [Claude Code](https://code.claude.com). Each plugin lives in its own folder and installs on its own.

| Plugin | What it does |
| --- | --- |
| [`toast-notify`](toast-notify/) | Native Windows toast (bottom-right) whenever Claude Code needs your permission or is waiting for input, even when you're tabbed out. |
| [`usage-widget`](usage-widget/) | Small always-on-top widget showing your **Session** and **Weekly** usage limits, color-coded green → yellow → orange → red. |
| [`phone-approve`](phone-approve/) | Sends permission prompts and clarifying questions to your phone over WhatsApp when you've stepped away from the laptop, and waits for your tap. Requires deploying your own free Cloudflare Worker — see its README. |

Works with Claude Code in the terminal and in the VS Code extension (also Cursor / Windsurf / VS Code Insiders).

## Install

1. Open Claude Code (terminal or the VS Code panel) and run:

   ```
   /plugin marketplace add ChasingHunter/claude-code-windows-kit
   /plugin install toast-notify@claude-code-windows-kit
   /plugin install usage-widget@claude-code-windows-kit
   ```

2. **Restart every Claude Code session that's already open** (close the chat
   and start a new one, or reload the VS Code window). Plugins only load when a
   session starts, so an already-open session won't use them.
3. Check it worked:
   - **usage-widget**: a small "Claude usage" box appears in the bottom-right
     corner within a few seconds. The numbers fill in within about a minute.
   - **toast-notify**: ask Claude to run any command that needs your
     approval. A Windows notification pops up; clicking it jumps back to that
     chat.

`toast-notify` and `usage-widget` need nothing else: they use PowerShell and
.NET, which come with Windows.

`phone-approve` (WhatsApp approvals) needs about 15 minutes of one-time setup
with free Cloudflare and Meta accounts. Install it the same way
(`/plugin install phone-approve@claude-code-windows-kit`), then follow
[its setup guide](phone-approve/README.md#setup).

## Requirements

- Windows 10 or 11
- A recent Claude Code version
- `usage-widget` needs a Claude Pro/Max subscription login (API-key logins have no session/weekly limits to show)
- `phone-approve` needs a free Cloudflare account and a Meta developer account, and you deploy your own Cloudflare Worker — see [its README](phone-approve/README.md) for setup

Nothing else to install for `toast-notify` and `usage-widget`: they use PowerShell and the .NET Framework that ship with Windows. `phone-approve`'s Worker is a small TypeScript project you deploy yourself.

## If something doesn't show up

- **Nothing happens at all**: the Claude Code session was started before the
  plugin was installed or updated. Start a new chat.
- **The usage widget disappeared**: its **×** closes it until you start a new
  chat (or run `/clear`); **−** only minimizes it to the taskbar.
- **The widget says "updated Xh ago"** right after opening: it's showing the
  last saved numbers while it fetches new ones ("· refreshing"); they update
  within a minute or two.
- Each plugin keeps two small logs under
  `%LOCALAPPDATA%\claude-code-windows-kit\<plugin>\`: `activity.log` (what
  it did, one line per event) and `error.log` (what went wrong). Each is
  capped at 128 KB; when full it's renamed to `.1` (replacing the previous
  one) and a new file starts, so the logs never take more than about 2 MB
  in total. They record tool, folder and event names, never your prompts,
  commands or messages.

## Uninstall

```
/plugin uninstall toast-notify@claude-code-windows-kit
/plugin uninstall usage-widget@claude-code-windows-kit
/plugin uninstall phone-approve@claude-code-windows-kit
```

Optional cleanup of generated files: delete `%LOCALAPPDATA%\claude-code-windows-kit` (this also removes `phone-approve`'s local config) and the registry keys `HKCU\Software\Classes\AppUserModelId\ClaudeCode.WindowsKit` and `HKCU\Software\Classes\cckit-open`. One-line version, paste into PowerShell:

```powershell
Remove-Item "$env:LOCALAPPDATA\claude-code-windows-kit" -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item 'HKCU:\Software\Classes\AppUserModelId\ClaudeCode.WindowsKit' -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item 'HKCU:\Software\Classes\cckit-open' -Recurse -Force -ErrorAction SilentlyContinue
```

If you deployed `phone-approve`'s Cloudflare Worker, that's separate cloud infrastructure the one-liner above can't reach — tear it down yourself with `npx wrangler delete` from `phone-approve/worker`.

## Privacy

Everything runs locally, with one exception. `toast-notify` and `usage-widget` never send anything anywhere: `usage-widget` reads your limits by running Claude Code's own `claude -p /usage` command, and no tokens or credentials are read by either script.

`phone-approve` is the exception: to relay a prompt to your phone, it necessarily sends some of your session's text off the machine. Specifically, the tool name and a short summary of what it's about to do — a shell command, a file path, a URL, or a clarifying question and its answer options — is sent to **your own Cloudflare Worker** (deployed under your own account) and then to **Meta/WhatsApp** to display and deliver the message. Nothing else leaves the machine: no file contents, no other tool output, no telemetry. If you don't install `phone-approve`, this doesn't apply to you at all.

## Releases

Each plugin is tagged and released independently, as `<plugin>-v<version>` (e.g. `toast-notify-v1.2.1`). See [Releases](https://github.com/ChasingHunter/claude-code-windows-kit/releases) for per-plugin changelogs generated from commit history.

## Trademarks

No third-party logos are included in this repo. `toast-notify` builds its icon on your machine from the VS Code and Claude icons already installed there.

## License

MIT

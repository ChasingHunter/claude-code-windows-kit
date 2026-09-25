# phone-approve

Send Claude Code's permission prompts — and its clarifying questions — to
your phone over WhatsApp when you've stepped away from the laptop. Tap
**Approve** or **Deny** (or pick an answer) from wherever you are; Claude
Code picks up the decision and continues.

```
PermissionRequest / PreToolUse hook (PowerShell)
  --HTTPS, bearer secret-->
Cloudflare Worker + Durable Object
  --Graph API-->
WhatsApp
  <--webhook (button/list tap or text reply)--
Cloudflare Worker
  <--poll decision--
PowerShell hook
```

No local daemon. The Worker holds request state in a Durable Object, so
several prompts (or a laptop that's asleep) never race each other.

## What it does

- **Idle-only**: the hook checks how long the laptop has been idle
  (`GetLastInputInfo`). If you're actively at the keyboard, nothing is sent —
  the normal local permission dialog shows as usual.
- **Permission prompts**: any tool that needs a yes/no (Bash, Edit, Write,
  ...) shows up on WhatsApp with **Approve**/**Deny** buttons.
- **Clarifying questions**: when Claude uses `AskUserQuestion`, each question
  is sent as a WhatsApp list message; answers come back the same way a local
  answer would.
- **Comes back to you**: if you return to the laptop while a prompt is
  waiting (any local key/mouse input), the phone flow is cancelled and the
  normal local dialog takes over instead.

## Install

```
/plugin marketplace add ChasingHunter/claude-code-windows-kit
/plugin install phone-approve@claude-code-windows-kit
```

Then follow **Setup** below — there's no cloud infrastructure to inherit,
you deploy your own Worker under your own Cloudflare and Meta accounts.

## Setup

This takes about 15 minutes the first time. You'll need a free Cloudflare
account and a Meta developer account.

### 1. Meta: create a WhatsApp-enabled app

1. Go to [developers.facebook.com](https://developers.facebook.com/) →
   **My Apps** → **Create App** → choose **Business** as the app type.
2. In the app dashboard, add the **WhatsApp** product.
3. Under **WhatsApp → API Setup** you'll see a Meta-provided **test phone
   number** — this is what your bot sends messages from. No need to buy a
   number for personal use.
4. Under **API Setup → To**, add your own phone number as a recipient and
   verify it with the code Meta sends you.
5. Note the **Phone number ID** shown on this page — that's
   `WA_PHONE_NUMBER_ID`.
6. Under **App settings → Basic**, note the **App Secret** — that's
   `WA_APP_SECRET`.

### 2. Meta: create a permanent access token

The token shown by default on the API Setup page is temporary (expires in
24 hours) — you need a permanent one:

1. [business.facebook.com/settings](https://business.facebook.com/settings)
   → **Users → System Users** → **Add** → create a system user with **Admin**
   access.
2. **Add Assets** → assign your WhatsApp app to that system user with **Full
   control**.
3. **Generate New Token** → select your app → scope
   `whatsapp_business_messaging` (and `whatsapp_business_management` if you
   want to manage the number later) → **Never expire**.
4. Save that token — that's `WA_TOKEN`. It's shown once.

### 3. Deploy the Cloudflare Worker

```powershell
cd phone-approve\worker
npm install
npx wrangler login
npx wrangler deploy
```

This prints your Worker's URL, e.g.
`https://phone-approve.<your-subdomain>.workers.dev`.

Then set the secrets it needs (each command prompts you to paste the
value):

```powershell
npx wrangler secret put WA_TOKEN             # the permanent System User token from step 2
npx wrangler secret put WA_PHONE_NUMBER_ID   # from step 1
npx wrangler secret put WA_APP_SECRET        # from step 1
npx wrangler secret put WA_VERIFY_TOKEN      # make up any random string; you'll reuse it in step 4
npx wrangler secret put OWNER_WA_ID          # your phone number, digits only, e.g. 15551234567 (no +, no spaces)
npx wrangler secret put LAPTOP_SECRET        # make up a long random string; the laptop hook uses this to call the Worker
```

### 4. Meta: point the webhook at your Worker

1. WhatsApp → **Configuration** → **Webhook** → **Edit**.
2. **Callback URL**: `https://<your-worker>.workers.dev/webhook`
3. **Verify token**: the same value you set as `WA_VERIFY_TOKEN` above.
4. Click **Verify and save** — the Worker's `GET /webhook` handler answers
   Meta's verification challenge.
5. Under **Webhook fields**, subscribe to **messages**.
6. Link your WhatsApp Business Account to the app, otherwise Meta only
   delivers the dashboard's **Test** events and never your real replies.
   This works for the free test number too. In
   [Graph API Explorer](https://developers.facebook.com/tools/explorer/),
   select **your app** under **Meta App**, generate a token, set the method
   to **POST** and submit the path
   `<WhatsApp Business Account ID>/subscribed_apps` (the ID is on
   **WhatsApp → API Setup**, next to the Phone number ID). It should return
   `"success": true`; a **GET** on the same path should now list your app.

### 5. Laptop: run setup

```powershell
cd phone-approve\scripts
.\setup.ps1
```

It asks for your Worker URL and the `LAPTOP_SECRET` value from step 3, and
writes `%LOCALAPPDATA%\claude-code-windows-kit\phone-approve\config.json`.

### 6. Open the 24-hour window

Meta only lets a WhatsApp business number message you freely for 24 hours
after you last messaged it. From your phone, send the bot **"hi"** (to the
test number from step 1). The Worker replies to confirm it's listening.
**Do this any time you're about to go AFK for a while** — if the window has
closed, the Worker's send fails (Meta error `131047`) and the hook falls
through to the normal local dialog rather than blocking you.

### 7. Test it

Set `idleMinutes` to `0` temporarily (edit config.json, or re-run
`setup.ps1`), then ask Claude to run a shell command. You should get a
WhatsApp message with Approve/Deny buttons almost immediately. Set
`idleMinutes` back to a real value (default 5) once confirmed.

## Config

`%LOCALAPPDATA%\claude-code-windows-kit\phone-approve\config.json`:

```json
{
  "workerUrl": "https://phone-approve.your-subdomain.workers.dev",
  "secret": "...",
  "idleMinutes": 5,
  "timeoutMinutes": 25,
  "pollSeconds": 2,
  "askMode": "denyWithAnswer"
}
```

| Field | Default | Meaning |
| --- | --- | --- |
| `idleMinutes` | 5 | How long the laptop must be idle before a prompt is relayed to your phone. |
| `timeoutMinutes` | 25 | How long to wait for a phone reply before giving up and showing the normal local dialog. |
| `pollSeconds` | 2 | How often the hook checks the Worker for a decision. |
| `askMode` | `denyWithAnswer` | How `AskUserQuestion` answers are returned to Claude — see below. |

Missing or invalid config → the hook exits silently and the local dialog
behaves exactly as if this plugin weren't installed.

## How clarifying questions are answered

Claude Code's hooks don't currently document a confirmed way for a
`PermissionRequest` hook to fill in `AskUserQuestion`'s answers directly (see
**Implementation notes** below), so this plugin uses a `PreToolUse` hook
(matcher `AskUserQuestion`) instead, and offers two strategies via `askMode`:

- **`denyWithAnswer`** (default): the hook denies the tool call and feeds
  your phone's answer back to Claude as the deny reason, one line per
  question: `The user answered from their phone (WhatsApp): "<question>" →
  <answer>. Treat this as the user's answer and continue.` This is the
  well-documented, guaranteed-to-work mechanism (`permissionDecisionReason`
  is how Claude reads denial feedback) — Claude then proceeds using your
  answer rather than actually asking again.
- **`updatedInput`**: the hook allows the call and rewrites its input to
  include the answers directly (mirroring how the Agent SDK's `canUseTool`
  callback answers `AskUserQuestion`). This is a closer match to a "real"
  answer, but whether `updatedInput` is honored for a `PreToolUse` hook on
  `AskUserQuestion` specifically was **not** confirmed in Claude Code's
  public docs at the time this was written. Switch to it only after you've
  verified it live in your own setup (see Setup step 7 — try a prompt that
  triggers a clarifying question and watch the transcript).

For a question with multiple choices, WhatsApp shows a list message; for
`multiSelect` questions, the options are also numbered in the message body
and you can reply with comma-separated numbers (e.g. `1,3`). There's always
a trailing "Other (type reply)" option — tap it, then type your answer as a
plain WhatsApp message.

## Troubleshooting

When a prompt can't be relayed, the hook falls back to the normal local
dialog and writes the reason to
`%LOCALAPPDATA%\claude-code-windows-kit\phone-approve\error.log`.

| Symptom | Cause |
| --- | --- |
| `error.log` shows code `190` | `WA_TOKEN` expired — you used the temporary 24-hour token. Create the permanent one (step 2) and `npx wrangler secret put WA_TOKEN` again. |
| `error.log` shows code `131047` | The 24-hour window closed. Send the bot "hi" (step 6 of Setup). |
| Messages arrive on the phone but taps and "hi" get no response | The WhatsApp Business Account isn't linked to your app (Setup step 4, item 6). |
| Phone says "⏹ handled on laptop" right away | Laptop input (mouse or keyboard) was seen after the prompt was sent, so the local dialog took over. Working as intended. |

`npx wrangler tail` in `phone-approve\worker` shows the Worker's live logs.

## Uninstall

```
/plugin uninstall phone-approve@claude-code-windows-kit
```

Then, optionally, delete the local config and the Worker:

```powershell
Remove-Item "$env:LOCALAPPDATA\claude-code-windows-kit\phone-approve" -Recurse -Force -ErrorAction SilentlyContinue
cd phone-approve\worker
npx wrangler delete
```

## Limitations

- **Subagent permission prompts may not trigger `PermissionRequest`** — this
  is a known Claude Code issue
  ([anthropics/claude-code#23983](https://github.com/anthropics/claude-code/issues/23983)).
  A prompt from inside a subagent may just show the normal local dialog
  without ever reaching this plugin.
- **`AskUserQuestion` support depends on `PreToolUse` firing for it**, and on
  Claude accepting either a deny-with-reason or an `updatedInput` answer in
  place of actually asking — see "How clarifying questions are answered"
  above.
- **The 24-hour window.** WhatsApp only lets a business number message you
  freely for 24 hours after your last message to it. Send "hi" before going
  AFK for longer than that (step 6).
- **Command and file-path text is sent to Meta.** See Privacy in the root
  README — this plugin is the one exception to "nothing leaves the machine"
  in this repo, because relaying a prompt to your phone requires sending its
  text somewhere.
- Not supported: an "always allow" button (updating permission rules from
  the phone), answering things other than `AskUserQuestion` and plain
  permission prompts, and WhatsApp message templates for messaging outside
  the 24-hour window.

## Privacy

See the root [README's Privacy section](../README.md#privacy) — this plugin
is the one exception to "nothing leaves the machine" in this repo.

## Implementation notes

- The `PermissionRequest` hook's documented decision output is
  `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny","message":"..."}}}`,
  confirmed against Claude Code's own docs (`/docs/en/hooks`,
  `/docs/en/hooks-guide`) while building this plugin. `timeout` in a hook
  definition is in **seconds**; the documented default is 600s for
  `command`/`http`/`mcp_tool` hooks, with no documented maximum — this
  plugin's hooks set it to 1800 (30 minutes) to comfortably cover
  `timeoutMinutes`.
- `updatedInput` is documented only alongside `PreToolUse`'s
  `permissionDecision` field, never alongside `PermissionRequest`'s
  `behavior` field — that's why `AskUserQuestion` is handled via a dedicated
  `PreToolUse` hook (matcher `AskUserQuestion`) rather than through
  `PermissionRequest`, and why the normal `PermissionRequest` hook
  explicitly skips `AskUserQuestion` (to avoid double-handling the same
  call).
- The inbound WhatsApp webhook shape for a **list message** reply
  (`interactive.list_reply.{id,title}`, used for `AskUserQuestion`) is the
  long-stable, widely documented Cloud API shape, symmetric with the
  confirmed **button** reply shape (`interactive.button_reply.{id,title}`)
  — Meta's own docs page with a literal example of the list-reply payload
  could not be fetched in full while building this plugin, so treat it as a
  soft confirmation, not a doc-quoted one, if WhatsApp ever changes it.

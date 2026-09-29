# Telegram remote control

The optional Telegram bot lets you check on and steer your live run sessions from your phone. It is off unless configured. It answers only the Telegram user IDs you allow-list, and only in a private chat with the bot, never in a group.

> [!WARNING]
> Anyone on the allow-list can type into sessions that run with full access to your machine, which amounts to a shell on it. Pane text and reports also pass through Telegram's servers, and bot chats aren't end-to-end encrypted, so anything a session prints can end up there.

## Setup

1. Create a bot with [@BotFather](https://t.me/BotFather) and copy its token.
2. Find your numeric Telegram user ID (for example by messaging [@userinfobot](https://t.me/userinfobot)).
3. Add both to Rails credentials (`bin/rails credentials:edit`):

   ```yaml
   telegram:
     bot_token: "<BotFather token>"
     allowed_user_ids:
       - "<your numeric Telegram user id>"
   ```

   or set `TELEGRAM_BOT_TOKEN` and `TELEGRAM_ALLOWED_USER_IDS` (comma-separated) in the orchestrator's environment (`RemoteControl::Adapters::Telegram::Configuration`).
4. Restart the orchestrator (`bin/service restart`) so the running instance sees the new credentials.

The app polls Telegram every five seconds (`PollTelegramUpdatesJob`, `config/recurring.yml`), so it only needs outbound internet access; it does not need a public URL. Telegram's [`getUpdates`](https://core.telegram.org/bots/api#getupdates) polling API doesn't work while a webhook is configured, so if this bot ever had one, clear it once:

```sh
bin/rails runner 'RemoteControl::Adapters::Telegram::Client.new.delete_webhook'
```

Use one bot per running instance: Telegram hands each message to a single poller, so two instances sharing a bot split your messages between them. `bin/sandbox start --telegram` takes a separate bot for this reason (see [operating.md](./operating.md#the-sandbox)).

## Commands

The app registers these with Telegram, so tapping **/** or **Menu** in the chat lists them; `/help` gives the long form.

| Command | What it does |
| --- | --- |
| `/panes` | Every live session: its run, workspace, what herdr says it is doing, and its last report. |
| `/idle` | Only the live sessions that aren't working: idle, finished, blocked at a prompt, or reported idle. |
| `/pane <run>` | Where that session stands. If it has reported (`report_idle`) and hasn't gone back to work since, you get that recap. Otherwise you get its live pane, and the message updates itself every few seconds for 3 minutes. If the session reports during that time, the message says so and the recap follows. |
| `/screen <run> [lines]` | The raw newest lines of the pane, once (default 200, up to 1000). A long read is split over up to 5 messages, oldest first; whatever still doesn't fit is dropped from the top, and the first message says how many lines that was. Give a smaller number for just the bottom of the screen. |
| `/report <run>` | That run's newest recap, rendered as Markdown. This also works after the session is closed. |
| `/send <run> <text>` | Types `<text>` into the session as live input, exactly like the run screen's message box. |
| `/send <text>`, or just type | The same, to the run you last looked at or wrote to (`/pane`, `/screen`, `/report`, `/send <run>` or a reply), for up to 12 hours. Starting with another run's four-character ref or full id still sends there. |

`<run>` is the run id's last four characters (the lists print tappable commands such as `/pane_33bd` and `/screen_33bd`), a prefix of the worktree name, or the full run id. Leave it out (`/screen 120`, `/pane`, `/report`) to mean the run you last looked at or wrote to. Every message the bot sends about a run starts with `run <id> ·`, and **replying to one of those messages sends your reply to that run**.

Session status comes from herdr and is refreshed every 30 seconds, so it can lag by up to that much.

## Adding another chat platform

Telegram is one adapter behind a platform-neutral core, so Discord, Slack or Matrix could sit beside it:

- `app/services/remote_control/` is the core. `Processor` answers commands, finds runs, remembers each chat's run, and talks to sessions. `Views` renders runs, panes and recaps as plain text. `Commands` is the one command list, which feeds both the help text and each platform's command menu. `Message` is what every adapter hands in.
- `RemoteControl::Adapter` is the contract, documented in the class. An adapter receives messages, but only from one-to-one chats, never groups. It hands each one to `RemoteControl::Processor.call(adapter, message)` and says who is on its allow-list. It sends text and a monospace pane. Optionally it edits a pane (live `/pane`), renders Markdown (recaps), publishes a command menu and makes commands tappable. The defaults cover whatever it can't do.
- `RemoteControl::Adapters::Telegram` is the reference: `Adapter` (event parsing and HTML rendering), `Client`, `Configuration`, and `Poller` (run by `PollTelegramUpdatesJob` from `config/recurring.yml`). `spec/support/fake_remote_control_adapter.rb` is the smallest adapter there is.
- Register the new adapter in `RemoteControl::Adapters.registry`, and give it a way in: a recurring poll job, a webhook route, or a gateway connection.
- A sandbox (`bin/sandbox`) refuses every adapter unless it is opted in by name (`WORKFLOW_SANDBOX_<NAME>=1`, see `Orchestrator::Sandbox.allows_remote_control?`), so add a `--<name>` flag to `bin/sandbox` that sets it with a sandbox-only bot or account.
- Test it the way the Telegram adapter is tested: a local fake of the platform's API (`lib/fake_telegram/`) and an end-to-end spec driving runs through the fake herdr (`spec/integration/telegram_remote_control_spec.rb`).

The design history is in [remote-control.md](./remote-control.md).

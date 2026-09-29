# Remote control for live run sessions

> This is a design record, kept for its reasoning (see [the docs index](./README.md#design-records)).
> For how to use remote control today, see [telegram.md](./telegram.md). The "admin chat" it
> discusses has been removed, and "the operator" means whoever runs the orchestrator.

Status: **partly implemented.** Written 2026-09-27 on
`workflow/plan-do-not-implement-replacing-the-workspace-ad-33bd`.

## Update, 2026-09-28: Telegram is now an adapter

The `Telegram::*` classes named below have moved. The chat-independent logic is now
`RemoteControl::Processor`, `RemoteControl::Views`, `RemoteControl::Commands`
and `RemoteControl::Chunker`. Telegram is now `RemoteControl::Adapters::Telegram::{Adapter,
Client, Configuration, Poller}`, behind the `RemoteControl::Adapter` contract.
`StreamTelegramPaneJob` is now `StreamPaneJob` (with an `adapter:` argument), and
`PollTelegramUpdatesJob` only calls the poller. See [telegram.md](./telegram.md#adding-another-chat-platform),
"Adding another chat platform".

## Update, 2026-09-27: what shipped

The operator decided to **remove the admin chat outright (D2), keep the
Telegram plumbing, and redesign the Telegram side from scratch as plain
commands**. That landed on the same branch, ahead of the phased plan below:

- **Removed:** everything in §6.1. That is the admin-chat models, driver and
  providers, `AdminChatPolicy`, the dormant MCP tools and
  `AdminChatAuthorization`, the turn, delivery and progress jobs, the
  controllers, routes, views, drawer JS and CSS, the `chat` worker pool, the
  progress recurring job, the specs, and the tables
  (`20260927090000_drop_workspace_admin_chats`, which also drops
  `telegram_conversations`).
- **Kept:** `Telegram::Client` (trimmed to `sendMessage`, `sendRichMessage`,
  `getUpdates` and `deleteWebhook`), `Telegram::Configuration`,
  `PollTelegramUpdatesJob` and `TelegramUpdateCursor`.
- **New `Telegram::UpdateProcessor`:** `/panes`, `/idle`, `/pane <run>`,
  `/screen <run> [lines]`, `/report <run>`, `/send <run> <text>`, and reply
  routing.
  - `/pane` shows the session's latest recap if it has reported and herdr
    (asked live) doesn't say it's working again.
  - Otherwise `/pane` sends the live pane, and `StreamTelegramPaneJob` edits
    that message every 5 s for 3 minutes. If the session reports in the
    meantime, it marks the message and sends the recap under it.
  - `/screen` is the one-off raw pane. A reply
  to any bot message that starts with `run <id> ·` goes to that run.
  - Everything the bot does maps directly onto `RunSessionRunner.snapshot` or
    `prompt!`, or onto the checkpoints.
  - It is stateless: the new design needs no Telegram tables at all.
  - It answers allow-listed users in their private chat with the bot, and no
    one else.
  - Tappable `/pane_33bd`-style commands stand in for inline keyboards.
- **New `Telegram::Chunker`:** splits on line boundaries and never breaks a
  fenced code block; pane tails are trimmed from the top.

**Still open from the plan below:**

| Item | Where |
| --- | --- |
| D1, loopback binding | phase 0 |
| `RunActions` extraction | phase 1 |
| Raw keys and the pane panel on the web | phase 2 |
| Pushed notifications | phase 3 |
| Queue, Close session and Remove worktree from Telegram, with confirmations | phase 4 |

Read those sections as the plan for what's left. Where they describe the old
admin chat as still present, that is now history.

The proposal: remove the "workspace admin chat" and its Telegram front end, and
put a thin remote-control transport in their place. It acts directly on the
run sessions the operator already has. There is no agent in the loop. The
session is the intelligence, and the phone is a keyboard and a screen for it.

Contents:

1. [Inventory: what exists today](#1-inventory-what-exists-today)
2. [What remote control needs, against what Rails already owns](#2-what-remote-control-needs)
3. [Telegram UX](#3-telegram-ux)
4. [Web](#4-web)
5. [Architecture](#5-architecture)
6. [Removal and migration](#6-removal-and-migration)
7. [Alternatives rejected](#7-alternatives-rejected)
8. [Spec coverage](#8-spec-coverage)
9. [Phased implementation plan](#9-phased-implementation-plan)
10. [Decisions for the operator](#10-decisions-for-the-operator)

---

## 1. Inventory: what exists today

Everything below was traced through the code on this branch. The usage numbers
come from a read-only query of `storage/production.sqlite3` on 2026-09-27.

### 1.1 The admin chat, end to end

A **turn** starts in one of two places:

- Web: the drawer in `shared/_admin_chat_launcher` (rendered on every page by
  `layouts/application.html.erb:84`) posts to
  `WorkspaceAdminChatMessagesController#create`.
- Telegram: free text in a chat that has a workspace selected goes through
  `Telegram::UpdateProcessor#handle_message`.

Both paths call `Orchestrator::WorkspaceAdminChatDriver::Runner.start_turn!`.
It locks the `WorkspaceAdminChat` row, creates a user and assistant
`WorkspaceAdminChatMessage` pair, and enqueues `WorkspaceAdminChatTurnJob` on
the dedicated `chat` queue (`config/queue.yml`, 2 threads).

`Runner.perform_turn` then spawns a **one-shot, non-interactive CLI** in
`Workspace#root_path` (the parent of `main` and every run worktree):

| Provider | Command (from `build_args`) | Effective permissions |
| --- | --- | --- |
| `ClaudeProvider` | `claude -p --output-format stream-json … --permission-mode bypassPermissions [--resume id] <prompt>` | **Full access.** No settings file and no sandbox are passed. |
| `CodexProvider` | `codex exec --json --sandbox workspace-write --skip-git-repo-check <prompt>` (a resume keeps the original sandbox) | Can write anywhere under the workspace root, which includes every live run's worktree. |
| `OpenCodeProvider` | `opencode run --format json --auto …` | Full access. |

Streamed events are folded into the assistant row (`apply_event!`). The CLI's
session id is saved per provider so the next turn can `--resume` it, and if
that session has vanished, `reconstruct_and_retry!` replays the transcript
into a fresh one. `cancel_turn!` kills the process group by its stored pid.

**Security finding.** `Orchestrator::AdminChatPolicy` says the chat is
"confined to reading", with a Claude sandbox settings file and Codex `-c`
overrides. **Nothing calls it.** `grep AdminChatPolicy app config lib`
matches only its own definition. So the one Telegram-reachable agent runs
with **write access to every run worktree and to `main`**, which is the exact
opposite of what the policy's comment promises. That alone is a reason to
remove it rather than fix it up.

**MCP.** None of the three providers passes an `--mcp-config` or an MCP
server. `WorkspaceAdminChat#issue_capability!` and `.authenticate_capability`
are never called outside their model. `McpTools::AdminChatAuthorization`
reads `server_context[:admin_chat_id]`, which no endpoint ever sets. So the
chat cannot reach `queue_run`, `list_runs`, `get_run`, `read_session_pane`,
`send_to_session` or `read_run_prompt`. It can only do what a bare CLI in the
workspace root can do: read files, run `git` and `gh`, and (because the policy
was never applied) edit things. **It cannot control a run session at all**,
which is the thing the operator actually wants.

### 1.2 Telegram, end to end

- `PollTelegramUpdatesJob` (recurring, every 5 s, `config/recurring.yml`)
  exits early unless `Telegram::Configuration.polling_configured?`, which
  needs a bot token and at least one allowed user id. It calls `getUpdates`
  with `timeout: 0` from `TelegramUpdateCursor.for_bot.last_update_id + 1`,
  processes each update inside the cursor lock, and always advances the cursor
  (commit `7cf6e30`), even when an update raises.
- `Telegram::UpdateProcessor` handles **message** and **callback_query**
  updates only. It drops anything whose `from.id` is not on the allow-list.
  The commands are `/start` and `/workspaces` (inline keyboard,
  `callback_data "workspace:<id>"`), `/stop` (cancel turn), `/status`,
  `/provider`, `/model`, and `/reset`. Any other text becomes an admin-chat
  turn. `TelegramConversation` maps one Telegram chat id to one selected
  workspace.
- Responses: `start_live_response` opens a "draft" with
  `sendRichMessageDraft`. `RefreshTelegramAdminChatProgressJob` (recurring,
  every 4 s) sends `typing`, updates the draft, and "persists" each completed
  4096-character chunk with `sendRichMessage`. When the turn ends,
  `DeliverTelegramAdminChatResponseJob` sends whatever is left. Chunking is
  `each_char.each_slice(4096)`, so it splits mid-word, mid-code-fence and
  mid-Markdown-entity.
- `Telegram::Client` is a bare `Net::HTTP` JSON client with `sendMessage`,
  `sendChatAction`, `sendRichMessage`, `sendRichMessageDraft`,
  `answerCallbackQuery`, `getUpdates` and `deleteWebhook`. The two "rich"
  methods did deliver in production (all four Telegram-originated assistant
  rows carry `telegram_delivered_at`), so they work against this bot.

The only thing Telegram is wired to is the admin chat. It never sends a
notification about a run, never shows a checkpoint, and never touches a
session.

### 1.3 Live, dormant, dead

| Piece | State | Evidence |
| --- | --- | --- |
| Web drawer, `WorkspaceAdminChat*` controllers, `WorkspaceAdminChatTurnJob`, `Runner`, the 3 providers, `ProcessStream` | **Live but idle.** It still renders on every page and still works. | 2 chats and 18 messages in total. The last message is from **2026-07-29**, two months ago. Workspace 2's chat has been stuck at `status=running` with `active_turn_id` set since then: a wedged turn that nobody noticed. |
| Telegram poller, `UpdateProcessor`, the delivery and progress jobs | **Live code with no traffic.** The recurring jobs still fire every 4 s and 5 s. | 1 `TelegramConversation` and 4 Telegram turns, all on **2026-07-27**. The cursor was last advanced 2026-07-27 13:26. |
| `Orchestrator::AdminChatPolicy` | **Dead.** Nothing references it. | grep |
| `WorkspaceAdminChat#issue_capability!` / `.authenticate_capability`, `capability_token_digest` column | **Dead.** | grep |
| `McpTools::AdminChatAuthorization`, `ReadRunPromptTool`, `ReadSessionPaneTool`, `SendToSessionTool` | **Dormant and unreachable.** They are not in `RunMcpServer::TOOLS` or `AdminMcpServer::TOOLS`, and no specs cover them. | AGENTS.md "MCP Boundary" |
| `WorkspaceAdminChatMessage#telegram_message_id` | **Dead column.** Nothing writes it. | grep |
| `McpTools::RunPresenter` | **Live, and misnamed in its comment.** `get_run`/`list_runs` use it. Keep it. | |

### 1.4 Data and tables owned

| Table | Rows (prod) | Owner | Fate |
| --- | --- | --- | --- |
| `workspace_admin_chats` | 2 | `WorkspaceAdminChat` (`Workspace has_one`, `dependent: :destroy`) | drop |
| `workspace_admin_chat_messages` | 18 | `WorkspaceAdminChatMessage` (FK to the chat and, optionally, to the Telegram conversation) | drop |
| `telegram_conversations` | 1 | `TelegramConversation` (chat id → selected workspace) | replace with `telegram_chats` (§5.4), then drop |
| `telegram_update_cursors` | 1 | `TelegramUpdateCursor` | **keep** as is |

Nothing in these tables is needed after the change. The transcripts describe
an agent that is being removed.

Config owned: the `chat` worker pool in `config/queue.yml`, the
`poll_telegram_updates` and `refresh_telegram_admin_chat_progress` entries in
`config/recurring.yml`, and `telegram.bot_token` / `telegram.allowed_user_ids`
in credentials (or `TELEGRAM_BOT_TOKEN` / `TELEGRAM_ALLOWED_USER_IDS`, plus
`TELEGRAM_BOT_API_URL`).

### 1.5 A second finding: the live instance is not local-only

AGENTS.md ("MCP Boundary") and `AdminMcpEndpoint` both justify having no auth
with "Puma binds `127.0.0.1` only". That is **not true of the running
instance**:

```
$ lsof -nP -iTCP -sTCP:LISTEN | grep 3001
ruby  4805 stockn  6u  IPv4 …  TCP *:3001 (LISTEN)
```

`bin/production` runs `bin/rails server` without `-b`. Outside development,
Rails' `ServerCommand` defaults the host to `0.0.0.0`
(`default_host = environment == "development" ? "localhost" : "0.0.0.0"`).
`bin/production`'s own port probe uses `127.0.0.1`, but that only checks the
port is free. `config.hosts` is unset in production. So on whatever network
this machine is on, anyone can load the UI, type into any session
(`send_message`), close sessions, and use `/mcp/admin`'s `queue_run`. Because
sessions run with full access, that amounts to **unauthenticated remote code
execution on the LAN**.

This is separate from the rest of the design, but it decides §4. See decision
D1.

---

## 2. What remote control needs

For each capability: what Rails already has, and what is missing.

| Need | Already owned by Rails | Gap |
| --- | --- | --- |
| **List runs and sessions with live status** | `Run.active` (`current_runs` in `ApplicationController`, which is global across workspaces). `Run#status` covers queued, launching, running and awaiting_review. `RunSession#agent_status` is herdr's idle/working/blocked/done, refreshed every 30 s by `RunSessionReconcileJob`. `Run#kept_worktree?`. `RunConcurrency.limit` and `.in_flight`. | None for the data. Telegram needs a renderer for it. |
| **Pushed notifications** | `RunIdleReport.call` → `Herdr.notify` (idle with outcome). `RunSessionRunner.finish!` → `notify` (session ended). Both are **desktop-only** (herdr's `notification.show` draws on the operator's Mac). | (a) Nothing reaches the phone. (b) There is no single place to hook: the two `Herdr.notify` calls are separate. (c) A session that stops at a **menu or prompt without calling `report_idle`** is invisible. herdr reports `agent_status: "blocked"` and reconcile stores it, but nothing acts on the transition. (d) `mark_pane_lost!` (herdr workspace closed by hand) and a launch failure in `StartRunSessionJob` notify nobody. |
| **Newest checkpoint** | `Run#checkpoints` (chronological), `RunSession#result` mirrors the newest one. | Only the rendering (Markdown to Telegram, chunking). |
| **Pane snapshot** | `RunSessionRunner.snapshot(session, lines:)` → herdr `pane.read` (`strip_ansi: true`, `source: "recent"`). It returns nil when the pane is gone. | The web run screen doesn't show it. Telegram needs rendering. |
| **Send text** | `RunSessionRunner.prompt!(session, text)` → herdr `agent.prompt`. Used by `RunsController#send_message`. | None. |
| **Raw keys** (menus, permission prompts, Esc to interrupt) | `Herdr.agent_send_keys(pane_id, keys)` exists and is used with `["Enter"]` (codex trust prompt, unsent prompt nudge). | There is no session-level wrapper, no allow-list of key names, and **only `Enter` has been confirmed live**. The other key names (`Escape`, `Up`, `Down`, `Tab`, digits, `C-c`) must be checked against a real herdr pane before they are relied on, as with `SessionArgs`. |
| **Queue a run** | `QueueRunTool.call` and `RunsController#create` each build a run inline, duplicating run-id generation, worktree naming, status and `RunDispatchJob.perform_later`. | One shared `enqueue!` for both, and then for Telegram. |
| **Close session** | Its logic lives **inside `RunsController#close_session`**: `finish!` → `RunCompletion.call` → `WorktreeJanitor.release!`, plus the notice text. | Must move out of the controller so a second transport doesn't copy it. |
| **Remove worktree** | `WorktreeJanitor.remove_for_run!(run, force:)`. | Already a service. It only needs a confirmation step on the phone. |
| **Stop run** | `StopRunJob.perform_now`. | Same as above. (It wasn't asked for, but it's the other destructive button on the run screen.) |

### 2.1 Should an LLM sit in the loop?

**No.** Every item above is a deterministic call onto a service that already
exists. The intelligence the operator wants to reach is the session, and it
already reads free text: whatever the operator types gets forwarded to it
verbatim with `prompt!`. Putting a second model in front of it would:

- add a layer that can misroute or paraphrase an instruction meant for a
  session that has full access to a worktree;
- bring back a separate agent with its own permissions, state and failure
  modes. §1.1 shows how that went: it got write access by accident and wedged
  silently;
- cost money and add seconds to every tap, for routing that a reply or a
  button already does exactly.

The case for keeping one was free-text routing such as "tell the layouts run
to go ahead". It can be handled deterministically:

1. **Reply-to routing.** The operator replies to any message the bot sent
   about a run (§3.2). This is the normal path, because the notification they
   are reacting to is already on screen.
2. **Focus.** Text that isn't a reply goes to the chat's focused run, which is
   set by tapping **Focus** or with `/focus`.
3. **Name match.** `/say layouts go ahead`: if the first word matches exactly
   one active run's `worktree_name` or run-id suffix, the rest goes to that
   run. If it matches more than one, the bot answers with one button per
   candidate. If none, it says so.

What would justify an agent later: voice notes, or "summarise everything
that's running". Neither needs to live inside Rails. The operator's own
everyday Claude Code session, or any MCP client, can already call
`/mcp/admin`. If they want an LLM to drive sessions, the clean version is to
add `read_session_pane` and `send_to_session` to `/mcp/admin`, backed by the
same command layer (§5), and let their own client be the agent. That stays out
of scope here (decision D5).

---

## 3. Telegram UX

### 3.1 Commands vs inline keyboards

Use **both, with buttons as the main interface**. On a phone, tapping beats
typing a run id. Commands are there for typing, for the Telegram `/` menu
(`setMyCommands`), and for recovering when there is no recent message to tap.

Every message about a run ends with the **run keyboard**:

```
[ 📺 Pane ] [ 📝 Report ] [ 🎯 Focus ]
[ ⏎ Enter ] [ Esc ] [ 1 ] [ 2 ] [ 3 ]      ← only while agent_status is blocked
[ ⏹ Close session ] [ 🗑 Worktree ]         ← only when it applies
```

### 3.2 Mapping a conversation to a run

**Recommended: reply-to routing, plus a sticky "focused run" fallback.**

- Every message the bot sends about a run (a notification, a card, a pane
  snapshot, or a checkpoint) is recorded as `(chat_id, message_id) → run` in
  `telegram_run_messages`.
- A text reply to one of those messages is sent to that run with `prompt!`. A
  reply that starts with `/keys` sends keys to that run instead.
- Text that isn't a reply goes to the chat's `focused_run_id`, if that run
  still has a live session. Otherwise the bot answers "No focused run" and
  shows the list of active runs as Focus buttons.
- Before forwarding free text, the bot **echoes the target**: "→ `layouts-4f2a`
  (sent)". A misroute is then visible immediately, and the confirmation is
  itself a run message the operator can reply to.

Rejected: **a forum topic per run.** A topic per run is the neatest mental
model, but it needs either a supergroup with the bot as admin (which weakens
the "private chat only" rule in §3.4) or the newer private-chat topics, whose
Bot API support I couldn't confirm from here. It would also add topic
lifecycle work (create on launch, close on Close session). Worth revisiting
once the basics are in use (decision D4).

Rejected: **focus as the only mechanism.** It's too easy to type into the
wrong run after a notification from another run arrives.

### 3.3 Rendering long output

Telegram caps a message at 4096 characters after entity parsing, and callback
data at 64 bytes.

- **Pane snapshot.** Call `snapshot(session, lines: 40)` by default (herdr
  already strips ANSI). Send it as HTML `<pre>` with the text HTML-escaped,
  **trimmed from the top** so the newest lines survive, with a header line of
  run, `agent_status` and the time. Buttons: **Refresh**, which edits the same
  message in place with `editMessageText` instead of adding a new one,
  **More** (120 lines), and the key row when blocked. If the text is still too
  big, send it as a `pane-<run>.txt` document (`sendDocument`).
- **Checkpoints** are free-form GitHub-flavored Markdown (headings, tables,
  fenced code). Keep the proven `sendRichMessage(markdown:)` path, with
  **structure-aware chunking** instead of `each_slice(4096)`:
  - split on blank-line paragraph boundaries, then on line boundaries;
  - never split inside a fenced block (close it at the end of a chunk and
    reopen it with the same info string);
  - number the chunks `(1/3)`.

  If a checkpoint needs more than **3** chunks, send the first chunk and
  attach the full text as `checkpoint-<run>-<n>.md`.

  If `sendRichMessage` returns an error, fall back to `sendMessage` with plain
  text, so nothing gets lost to a rendering failure.
- **Notifications are short by design**: a title line and the first
  ~300 characters of the summary (`truncate` at a word boundary), with the run
  keyboard. **Report** opens the full checkpoint.
- **Lists** (`/runs`): one line per run with a status emoji, the worktree
  name, driver, `agent_status` and age, followed by one button per run that
  opens its card. Group by workspace only when more than one workspace has
  active runs.

### 3.4 Allow-list and security

**The threat model in one sentence: an allowed Telegram account is a shell on
this machine.** Sessions run with full access, and the bot types into them.

- **Keep `Telegram::Configuration.allowed_user_ids`** as the only identity
  check, and apply it to every update, including every callback query
  (`callback_query.from.id`), not only the chat.
- **Private chats only.** Ignore any update where `chat.type != "private"` or
  `chat.id != from.id`. That shuts out groups, where other members could read
  panes and press buttons on an allowed user's messages. It also means
  notifications can be sent to `chat_id = user_id` for each allowed user,
  provided they have pressed Start once. Telegram forbids a bot from starting
  a conversation.
- **Ignore bots** (`from.is_bot`), edited messages, and every update type
  except `message` and `callback_query` (the current `allowed_updates` already
  does this).
- **Confirm destructive actions** (Close session, Remove worktree, Stop,
  Queue) with a second button. It carries a **stateless signed token**:
  `x:<action>:<run pk>:<expires_unix>:<hmac8>`, where the HMAC is keyed from
  `secret_key_base`. That fits in 64 bytes and expires after 10 minutes, so an
  old confirmation in the scrollback can't be replayed. Non-destructive
  callbacks (`p:<run pk>` and similar) need no signature because they are
  still gated by the allow-list.
- **Re-check state when the button is pressed.** A button on a three-day-old
  notification must act on the run as it is now. If the session has ended,
  "no live session" is the answer, not an exception.
- **Key allow-list.** `send_keys!` accepts only a fixed set of key names, never
  arbitrary sequences.
- **Exposure to Telegram.** Pane text and checkpoints go to Telegram's
  servers. Bot chats are not end-to-end encrypted. Anything a session prints,
  including a secret it echoed, can end up there. Redaction is not reliable,
  so this is accepted rather than solved, and README should say so plainly.
- **The bot token is a credential.** Whoever holds it can read the incoming
  updates (and so everything the operator sends) and message the operator as
  the bot. They cannot act as an allowed user, because commands are
  authenticated by Telegram's `from.id`. Keep it in credentials. It must never
  appear in logs, and `Telegram::Client` raises with `description` only,
  which is already correct.
- **Audit.** Log every remote action at `info` with a `[remote]` tag,
  including user id, action, run id and, for text, its length but not its
  content. The Telegram chat is the operator-visible record.
- Rejected: a PIN or `/unlock` step. It adds little on top of Telegram's own
  device security for a single operator, and it gets in the way exactly when
  they're away. D6 covers it if they want it anyway.

### 3.5 The command set

| Command | Buttons equivalent | Does |
| --- | --- | --- |
| `/runs` | — | Active runs across all workspaces, one open-card button each. Shows the queued count and `in_flight/limit`. |
| `/run <ref>` | card button | Run card: task (first 300 characters), workspace, driver/model, `Run#status`, `agent_status`, age, newest checkpoint outcome and time, kept-worktree flag, run keyboard. |
| `/focus <ref>` | 🎯 Focus | Sets the chat's focused run. |
| `/pane [lines]` | 📺 Pane | Snapshot of the focused (or replied-to) run. |
| `/report [n]` | 📝 Report | Newest checkpoint, or the n-th back. |
| *(reply or plain text)* | — | `prompt!` to the replied-to or focused run. |
| `/say <ref> <text>` | — | `prompt!` with an explicit target (§2.1, name match). |
| `/keys <k…>` | key row | `send_keys!`, e.g. `/keys Down Down Enter`. |
| `/queue [workspace] <task>` | Driver buttons (claude, codex, opencode), then Confirm | `enqueue!` with `launched_by: "telegram"`. Workspace resolution works like `McpTools::WorkspaceResolution`: an explicit name, else the default. |
| `/close <ref>` | ⏹ → Confirm | Close session (same service as the web). Replies with the same "removed / kept worktree" notice. |
| `/rmworktree <ref>` | 🗑 → Confirm (then **Force** → Confirm if it's dirty or unpushed) | `remove_for_run!`. |
| `/stop <ref>` | on the card, → Confirm | `StopRunJob`. |
| `/workspaces` | — | Names, active-run counts, and the default. |
| `/help` | — | This table, briefly. |

`<ref>` is any of: the run's four-hex suffix (`33bd`), a unique prefix of the
worktree name (`layouts`), or the full run id. It resolves only among the most
recent runs (active first), and an ambiguous ref gets buttons.

**Notifications pushed** (decision D3 sets which ones are on):

| Event | Source | Message |
| --- | --- | --- |
| Idle: done | `RunIdleReport` | ✅ `<worktree>` done: first ~300 characters of the summary, run keyboard. |
| Idle: blocked or failed | `RunIdleReport` | ⚠️ / ❌ likewise, and with the key row if `agent_status` is blocked. |
| Waiting at a prompt | agent_status changes to `blocked` in `refresh!` with **no** report at the same time | ⏸ `<worktree>` is waiting at a prompt. Buttons: Pane, keys. This is the "permission prompt / menu" case. |
| Session died | `mark_pane_lost!` / `mark_process_lost!` via reconcile | 💀 `<worktree>` session ended (the pane was closed or the CLI exited). The worktree was kept or removed. |
| Launch failed | `StartRunSessionJob` rescue | 🚫 `<worktree>` failed to launch: `launch_error`. |
| Closed by the operator | `close_session` | **No notification.** The operator did it themselves. |

---

## 4. Web

**Can a phone reach it?** At the moment, yes: the instance listens on
`*:3001` (§1.5). The same fact is also the security hole. The design should
not depend on the LAN exposure staying. The right shape:

1. **Bind to loopback** (`bin/production` passes `-b 127.0.0.1`, or sets
   `BINDING`), which makes AGENTS.md's claim true.
2. For the phone, put the UI behind **Tailscale Serve** (`tailscale serve
   --bg 3001`). The phone reaches it over the tailnet, and the traffic lands on
   loopback. Optionally, Rails can check the `Tailscale-User-Login` header
   Serve adds and refuse anything without it. The alternative is an SSH
   tunnel, which is workable but clumsy on a phone. **Never** use a public
   tunnel (for example ngrok or Cloudflare Tunnel) without real auth in front.

That is decision D1, and the web half of remote control only exists if the
operator picks a reachable, private option.

**Is the run screen enough?** Nearly. A separate remote view isn't warranted.
The layout already has a viewport meta tag, mobile-first CSS
(`@media (min-width: …)` breakpoints), a global **current runs** drawer
(`current_runs`, across workspaces), and Turbo refresh streams per run and per
workspace. What's missing on the run screen:

- **A pane panel.** "Show pane" renders `snapshot(session, lines: 60)` in a
  `<pre>` with a Refresh button. It uses a plain GET and deliberately no
  auto-polling, because every read is a herdr socket call.
- **A key row** under the message box while the session is live: Enter, Esc,
  ↑, ↓, 1, 2, 3.
- **Mobile layout checks** on `runs/show`: long checkpoint Markdown and wide
  code blocks must scroll inside their panel, not across the page. Close and
  Remove stay as they are (both already use `data-turbo-confirm`).
- Removing the admin-chat drawer from the layout frees the space it took on
  small screens.

Rejected: a dedicated `/remote` page, a PWA with Web Push, a websocket pane
stream (xterm.js). Push needs HTTPS, a service worker and VAPID keys to do what
Telegram already does. A live pane stream is a second terminal emulator next to
the operator's own herdr client. The run screen plus Telegram notifications
cover the need.

---

## 5. Architecture

### 5.1 Principles, from CLAUDE.md

- Rails schedules and does not orchestrate. Remote control **adds no run
  state, no queue, and no decision-making**. It exposes the operations the web
  run screen already has, to another transport.
- There is **one command layer**. Telegram, the web controllers and the MCP
  tools all call it, and none of them has its own copy of "close a session".
- A transport handles parsing input, authorization, rendering and
  confirmation. It never calls `Herdr`, `RunCompletion` or `WorktreeJanitor`
  directly.
- Notifications are a **fan-out of events that already happen**. They never
  cause state changes.

### 5.2 Layers

```
 Telegram::UpdateProcessor ─┐                ┌─ RunsController (web)
   (router, auth, confirm)  │                │
 Telegram::Renderer         ├──► Orchestrator::RunActions ◄──┤
 Telegram::Keyboards        │     list / card / pane / say / │─ McpTools::QueueRunTool,
                            │     keys / enqueue / close /   │   (later) admin send/read tools
                            │     remove_worktree / stop     │
                            │            │
                            │            ▼
                            │   RunSessionRunner, RunCompletion, WorktreeJanitor,
                            │   StopRunJob, RunDispatchJob, Herdr   (unchanged owners)
                            │
 RunIdleReport ─┐
 RunSessionRunner (finish!, mark_*_lost!, blocked transition) ─┼─► Orchestrator::RunNotifications
 StartRunSessionJob (rescue) ─┘            │  → Herdr.notify (desktop, as today)
                                           └→ DeliverTelegramNotificationJob (per allowed user)
```

**Naming.** The command layer is `Orchestrator::RunActions`, not
`RemoteControl::…`. The web UI and MCP use it too, so "remote" would be
misleading. It sits with the other run services. There is no `RemoteControl`
namespace: the Telegram-specific pieces stay under `Telegram::`.

### 5.3 `Orchestrator::RunActions`

This is a `module_function` module, like its neighbours. Every method takes
model objects and plain values, returns a small `Result` (`ok?`, `message`,
`data`), and **catches its own expected errors** (`RunSessionRunner::Error`,
`Herdr::Error`, `WorktreeJanitor::Error`, `ActiveRecord::RecordInvalid`) into
a failed `Result`. Transports never need a rescue list.

| Method | Body (moved from, or delegating to) |
| --- | --- |
| `enqueue!(workspace:, task:, driver:, model: nil, launched_by:, launch_artifacts: [])` | Extracted from `RunsController#create` and `QueueRunTool.call`: run-id generation, `GitWorktree.name_for`, `status: "queued"`, `target_root`, the `ModelCatalog` check, save, `RunDispatchJob.perform_later`. Returns the run plus `queued_behind`/capacity. |
| `say!(run, text)` | `run.live_session` → `RunSessionRunner.prompt!`. |
| `send_keys!(run, keys)` | New `RunSessionRunner.send_keys!(session, keys)` with a `KEYS` allow-list → `Herdr.agent_send_keys`. |
| `pane(run, lines:)` | `RunSessionRunner.snapshot`, with `lines` clamped to 1..500. |
| `close_session!(run)` | **Moved out of `RunsController#close_session` and `#close_session_notice`**: finish!, RunCompletion, release!, and the kept/removed message. |
| `remove_worktree!(run, force:)` | `WorktreeJanitor.remove_for_run!`. |
| `stop!(run)` | `StopRunJob.perform_now(run.id)`. |
| `active_runs` / `resolve_ref(ref)` | Queries (`Run.active`, recent terminal runs with kept worktrees) and the `<ref>` resolution from §3.5. |

`RunsController`'s actions become thin wrappers that map a `Result` to
`notice`/`alert`. `QueueRunTool` maps it to a `ToolResponse`.

### 5.4 Telegram pieces

| File | Role |
| --- | --- |
| `app/services/telegram/client.rb` | **Keep.** Add `edit_message_text`, `send_document` (multipart), `set_my_commands`, and `answer_callback_query(text:)`. Read Telegram's `retry_after` on a 429 and raise a typed error so jobs can retry after that delay. |
| `app/services/telegram/configuration.rb` | **Keep.** Add `notify_events` (decision D3). |
| `app/services/telegram/update_processor.rb` | **Rewrite** as the router: authorize (§3.4) → callback or command or reply/free text → `Telegram::Commands`. |
| `app/services/telegram/commands.rb` | **New.** One method per row of §3.5. Each calls `RunActions` and hands the result to the renderer. Holds the confirmation-token sign and verify. |
| `app/services/telegram/renderer.rb` | **New.** Run card, run list, pane `<pre>`, Markdown chunker, notification text. Pure functions, easy to unit-test. |
| `app/services/telegram/keyboards.rb` | **New.** Builds `inline_keyboard` arrays and callback_data under 64 bytes. |
| `app/models/telegram_chat.rb` | **New** (replaces `TelegramConversation`). `telegram_chat_id` (unique), `telegram_user_id`, `focused_run_id` (FK `runs`, nullable, `on_delete: :nullify`). |
| `app/models/telegram_run_message.rb` | **New.** `telegram_chat_id`, `telegram_message_id`, `run_id` (FK), `kind`. Unique on `(chat_id, message_id)`. Pruned when its run is destroyed (`dependent: :delete_all` on `Run`). |
| `app/jobs/poll_telegram_updates_job.rb` | **Keep** unchanged, apart from the processor it calls. |
| `app/jobs/deliver_telegram_notification_job.rb` | **New.** `(run_id, event, payload)` → render and send to each allowed user, record `TelegramRunMessage`. Retries on 429 and network errors. A 403 ("bot was blocked" or "chat not found") is logged and dropped. |
| `app/services/orchestrator/run_notifications.rb` | **New.** `publish(run, event, **payload)`: `Herdr.notify` (the existing title, body and sound, moved here from `RunIdleReport`/`RunSessionRunner.notify`) plus `DeliverTelegramNotificationJob.perform_later` when Telegram is configured and the event is enabled. Enqueue with `after_all_transactions_commit`, the same pattern `start_turn!` needed. |

The **blocked transition** is handled in `RunSessionRunner.refresh!`. Remember
the previous `agent_status` before `update!`. If it changes to `"blocked"`
from anything else, and the session has no checkpoint in the last ~60 s (a
`report_idle(blocked)` notifies on its own), publish `:waiting`. Latency is up
to 30 s, the reconcile interval, which is acceptable.

---

## 6. Removal and migration

### 6.1 Deleted

**Code**
- `app/models/workspace_admin_chat.rb`, `workspace_admin_chat_message.rb`,
  `telegram_conversation.rb` (the last one after `TelegramChat` replaces it).
- `app/services/orchestrator/workspace_admin_chat_driver/` (`runner.rb`,
  `claude_provider.rb`, `codex_provider.rb`, `open_code_provider.rb`,
  `process_stream.rb`). Nothing outside the providers uses
  `ProcessStream`.
- `app/services/orchestrator/admin_chat_policy.rb`.
- `app/services/mcp_tools/admin_chat_authorization.rb`,
  `read_run_prompt_tool.rb`, `read_session_pane_tool.rb`,
  `send_to_session_tool.rb`. If D5 is "yes", pane and send come back later as
  `/mcp/admin` tools over `RunActions`, written fresh.
- `app/jobs/workspace_admin_chat_turn_job.rb`,
  `deliver_telegram_admin_chat_response_job.rb`,
  `refresh_telegram_admin_chat_progress_job.rb`.
- `app/controllers/workspace_admin_chats_controller.rb`,
  `workspace_admin_chat_messages_controller.rb`, and their routes.
- `ApplicationController#current_workspace_admin_chat` and its `helper_method`.
- `app/helpers/workspace_admin_chats_helper.rb`.
- `app/views/workspace_admin_chats/`, `app/views/workspace_admin_chat_messages/`,
  `app/views/shared/_admin_chat_launcher.html.erb`, and the render call in
  `layouts/application.html.erb`.
- `app/javascript/controllers/admin_chat_drawer_controller.js`.
- The admin-chat CSS in `app/assets/stylesheets/application.css`
  (`.chat-*`, `.chat-drawer*`).
- `Workspace has_one :workspace_admin_chat`.
- `Telegram::Client#send_rich_message_draft` and `send_chat_action`, unless
  the new transport uses them.

**Config**
- `config/queue.yml`: the `chat` worker pool and the comments that refer to it.
- `config/recurring.yml`: `refresh_telegram_admin_chat_progress`.

**Tables**, in one migration, after the code is gone:
`workspace_admin_chat_messages`, `workspace_admin_chats`,
`telegram_conversations`. Use `drop_table … if_exists: true` with the full
column definitions in `down`, following the existing `drop_*` migrations.

**Specs**: `spec/jobs/{workspace_admin_chat_turn,deliver_telegram_admin_chat_response,refresh_telegram_admin_chat_progress}_job_spec.rb`,
`spec/models/workspace_admin_chat{,_message}_spec.rb`,
`spec/requests/workspace_admin_chat{s,_messages}_spec.rb`,
`spec/services/orchestrator/workspace_admin_chat_driver/`,
`spec/services/orchestrator/opencode_provider_smoke_spec.rb` (a `:live_agent`
smoke test of the admin-chat `OpenCodeProvider` only), `spec/support/fake_admin_chat_cli_harness.rb`.
`spec/services/telegram/update_processor_spec.rb` is **rewritten**, not
deleted.

**Docs**
- README "Telegram admin chat" → "Remote control (Telegram)": setup, the
  command set, the security notes from §3.4. Also remove "operator chat" from
  the intro line.
- AGENTS.md "Operating Context": the remote-control paragraph now names
  `Telegram::UpdateProcessor` → `Orchestrator::RunActions`, and the loopback
  claim is fixed or made true (D1). In "MCP Boundary", drop the
  dormant-admin-chat paragraph.
- CLAUDE.md: the "Telegram" mention in the intro stays valid, so leave it.
- ARCHITECTURE.md lines 41 and 43 mention the admin chat's `ClaudeProvider`
  and `CodexProvider` as history. Reword them to past tense, or leave them,
  since that file is already historical.
- `McpTools::RunPresenter`'s comment: "how a run is described to the admin
  chat" → "to MCP callers".

### 6.2 Kept or renamed

| Kept | Why |
| --- | --- |
| `Telegram::Client`, `Telegram::Configuration`, `PollTelegramUpdatesJob`, `TelegramUpdateCursor` / `telegram_update_cursors` | This is the transport, and it works. The cursor must survive so no update is replayed or lost during the switch. |
| The credentials keys `telegram.bot_token` / `allowed_user_ids` | Same bot, same operator: no reconfiguration. |
| `McpTools::RunPresenter`, `WorkspaceResolution` | `get_run`/`list_runs`/`queue_run` depend on them. |
| `TelegramConversation` → **`TelegramChat`** | A rename plus a changed meaning (focused run instead of selected workspace). Build it as a new table rather than an in-place rename, because the old model stays live until cut-over. |

### 6.3 Order, and keeping Telegram working throughout

The one rule: **Telegram changes behaviour in exactly one deploy (phase 4),
and every phase before that is additive.** Before the cut-over, the old
admin-chat text path keeps working. After it, the same bot, token and cursor
serve the new commands.

1. Extract `RunActions` (no behaviour change).
2. Web pane panel and keys.
3. Notifications: new outbound messages. The old UpdateProcessor keeps
   handling inbound, so the operator gets notifications right away while the
   admin chat is still there. Replies to them aren't routed yet. Record
   `TelegramRunMessage` from this phase on, so phase 4 can route replies to
   notifications sent before it shipped.
4. **Cut-over**: the new UpdateProcessor and `telegram_chats`. The old
   admin-chat branch of the processor goes away in the same commit, so there
   is never a moment where plain text is routed ambiguously. The admin chat's
   web drawer still exists, but Telegram no longer reaches it.
5. Delete the admin chat, its jobs and config, and drop the tables.
   **`bin/service restart` straight after merging.** `queue.yml` and
   `recurring.yml` are read only at boot, so until the restart Solid Queue
   keeps firing `RefreshTelegramAdminChatProgressJob` every 4 s against a
   class that no longer exists. That is harmless but noisy, and the restart is
   what AGENTS.md prescribes. Before migrating, clear any leftover
   `WorkspaceAdminChatTurnJob` rows from `solid_queue_jobs`, including failed
   ones, because they reference a deleted class. Workspace 2's wedged `running`
   chat disappears with its table.
6. Docs sweep. Fold it into 4 and 5 where the text belongs, and keep a short
   final pass for README/AGENTS.md.

Because this repo is one of its own workspaces, phases 4 and 5 change code the
running instance hot-reloads (`WORKFLOW_HOT_RELOAD=1`). A session doing phase
5 should merge and restart in one step, not leave `main` ahead of the running
process's config.

---

## 7. Alternatives rejected

| Alternative | Why not |
| --- | --- |
| **Fix the admin chat** (apply `AdminChatPolicy`, wire an `--mcp-config` with `send_to_session`/`read_session_pane`) | This keeps a second agent, with its own sessions, turns, cancel logic and permissions, in front of sessions that can already read free text. It adds cost and latency on every message, plus a misrouting risk, all to wrap three service calls. It is also the kind of chaperone CLAUDE.md forbids. |
| **An LLM router only for free text** | Replies, focus and deterministic name matching (§2.1) cover it exactly. If an LLM is ever wanted, it belongs in the operator's own MCP client over `/mcp/admin`, not in Rails. |
| **A forum topic per run** | It's a good model, but it needs group admin (and so weakens private-only) or unverified private-chat topic support, plus topic lifecycle work. Deferred (D4). |
| **Focus-only routing** | It misroutes after a notification from another run. |
| **Telegram webhook instead of polling** | That needs a public HTTPS URL into a machine that should be loopback-only. 5 s polling latency is fine. |
| **Long-polling `getUpdates` (`timeout: 30`)** | It would hold one of the 3 `default` worker threads that dispatch and reconcile rely on. Keep `timeout: 0` every 5 s. |
| **Streaming the pane to Telegram** (a message edited live) | It hits the edit rate limits and duplicates the herdr client. Snapshot plus Refresh is enough. |
| **A dedicated `/remote` web view, PWA push, xterm.js pane** | See §4. The run screen plus Telegram covers it. |
| **A `RemoteControl` namespace for the command layer** | The web and MCP use the same operations, so it goes in `Orchestrator::RunActions`. |
| **Keeping the dormant MCP tools "for later"** | They authorize through a model that's being deleted. If D5 wants them, rewrite them over `RunActions` for `/mcp/admin`. |

---

## 8. Spec coverage

Follow CLAUDE.md: stub `Orchestrator::Herdr` everywhere, never open a socket,
and stub `Telegram::Client`, or point `TELEGRAM_BOT_API_URL` at a WebMock
stub. Never call the real API.

**`spec/services/orchestrator/run_actions_spec.rb`**
- `enqueue!`: creates a queued run with a run id and worktree name, enqueues
  dispatch, rejects a model the catalog doesn't list, and reports
  `queued_behind`.
- `say!`: prompts the live session. With no live session it returns a failed
  Result. A `Herdr::Error` becomes a failed Result.
- `send_keys!`: passes allow-listed keys through and rejects anything else
  without calling herdr.
- `pane`: clamps lines, and returns a failed Result when the pane is gone.
- `close_session!`: finishes the session, completes the run with the
  session's outcome, releases the worktree, and gives the kept/removed
  message. This is ported from the existing request spec. With no live session
  it fails cleanly.
- `remove_worktree!`, `stop!`: delegate, and map errors.
- `resolve_ref`: suffix, worktree prefix, full id, ambiguous, none.

**`spec/services/orchestrator/run_session_runner_spec.rb`** (extended)
- `send_keys!` guards: the session must be live and have a pane.
- `refresh!` publishes `:waiting` once, on the transition into `blocked`. It
  doesn't publish while the session stays blocked, or right after a
  checkpoint.

**`spec/services/orchestrator/run_notifications_spec.rb`**
- Still calls `Herdr.notify` with today's title, body and sound (the existing
  behaviour is kept).
- Enqueues the Telegram job only when Telegram is configured and the event is
  enabled, and only after the transaction commits.
- `RunIdleReport`, `finish!`, `mark_pane_lost!` and the `StartRunSessionJob`
  rescue each publish the right event (a job or service spec for each).

**`spec/jobs/deliver_telegram_notification_job_spec.rb`**
- Sends one message per allowed user and records a `TelegramRunMessage` for
  each.
- A 429 is retried after `retry_after`. A 403 is dropped without raising.

**`spec/services/telegram/update_processor_spec.rb`** (rewritten)
- Authorization: an unknown user, a group chat, `chat.id != from.id`, a bot
  sender, and a callback from an unknown user are all ignored.
- A reply to a run message goes to `say!` on that run. A reply with `/keys`
  goes to `send_keys!`.
- Plain text goes to the focused run. With no focus, it gets the "no focused
  run" answer and the run buttons. It is echoed with the target.
- Every command in §3.5 has a happy path plus its "no such run" and
  "ambiguous ref" paths.
- Destructive callbacks: the first tap asks for confirmation. A valid token
  acts. An expired token, a tampered HMAC, or a run whose state has changed
  since is refused and acts on nothing.

**`spec/services/telegram/renderer_spec.rb`**
- The pane trims from the top to fit, and HTML-escapes the text.
- The Markdown chunker splits on paragraphs, never inside a fence (closes and
  reopens it with its info string), numbers chunks, and switches to a document
  over 3 chunks.
- Callback data is always 64 bytes or less.

**`spec/services/telegram/client_spec.rb`** (new): request shapes for the
added methods, multipart `sendDocument`, and 429 parsing.

**`spec/requests/runs_controller_spec.rb`** (extended): pane panel, `send_keys`
action, and close/remove still behaving the same through `RunActions`.
**`spec/requests/admin_mcp_spec.rb`** / `queue_run_tool_spec.rb`: unchanged
behaviour through `enqueue!`.

**Removal phase**: `bundle exec rspec` stays green with the deleted specs
gone. Add a request spec that `/workspaces/:id/workspace_admin_chat*` now
returns 404 (routing), and that the layout renders without the launcher.

Every phase: `bundle exec rspec`, `bin/rubocop`, `git diff --check`.

---

## 9. Phased implementation plan

Each phase is sized to be one queued run. They are listed in dependency order.
Phases 0 and 2 are independent of the others.

**Phase 0: bind to loopback (security; do this first, pending D1).**
Pass `-b 127.0.0.1` (or `BINDING`) in `bin/production`. Correct AGENTS.md and
`AdminMcpEndpoint`'s comment if they still disagree. Optionally set
`config.hosts` in production. Add a `spec/bin/production_spec.rb` assertion on
the argv. `bin/service restart`. If D1 picks Tailscale, document
`tailscale serve --bg 3001` in README.

**Phase 1: extract `Orchestrator::RunActions`.**
Add `run_actions.rb` with `Result`, `enqueue!`, `say!`, `pane`,
`close_session!`, `remove_worktree!`, `stop!` and `resolve_ref`. Make
`RunsController#create/send_message/close_session/remove_worktree/stop` and
`QueueRunTool` delegate to it. No user-visible change. Specs as in §8.

**Phase 2: keys and pane on the web.**
Verify herdr key names live in a scratch pane (Enter, Escape, Up, Down, Tab,
1-9, C-c) and record the verified list in a comment, as `SessionArgs` does.
Add `RunSessionRunner.send_keys!` + `KEYS`, `RunActions.send_keys!`, a
`POST send_keys` member route, a pane panel with Refresh, a key row on
`runs/show`, and a mobile pass on the run screen.

**Phase 3: notifications fan-out.**
Add `Orchestrator::RunNotifications`, and route both existing `Herdr.notify`
call sites through it. Add the blocked-transition detection in `refresh!`, and
publish events from `mark_pane_lost!` and from the `StartRunSessionJob`
rescue. Add `TelegramRunMessage` (migration), `DeliverTelegramNotificationJob`,
`Telegram::Renderer` (notification text and Markdown chunker),
`Telegram::Keyboards` (buttons only, with a "handled in the next release"
answer for now), and `Configuration.notify_events`. The old admin-chat
processor is untouched, so inbound Telegram works as before.

**Phase 4: Telegram cut-over to run commands.**
Add `TelegramChat` (migration), `Telegram::Commands`, and the rewritten
`UpdateProcessor` (auth hardening, reply and focus routing, the full §3.5 set,
signed confirmations). Add the `Client` methods (`edit_message_text`,
`send_document`, `set_my_commands`, callback text), with `setMyCommands` called
once from a `bin/rails runner` step documented in README. Rewrite the
processor spec and the README Telegram section. After merging:
`bin/service restart` (not strictly needed for code-only changes under hot
reload, but it guarantees a clean boot), then smoke-test from the phone:
`/runs`, a pane, and a reply.

**Phase 5: delete the admin chat.**
Everything in §6.1: code, routes, views, JS, CSS, jobs, config entries,
dormant MCP tools, specs, the drop migration (including
`telegram_conversations`), and the docs sweep in AGENTS.md, README,
ARCHITECTURE.md and the RunPresenter comment. Clear any stale `solid_queue`
rows for the deleted job classes first. Merge and `bin/service restart` in the
same step.

**Phase 6 (optional, after some real use).** Depending on D4 and D5: per-run
forum topics, and `read_session_pane`/`send_to_session` on `/mcp/admin` over
`RunActions`.

---

## 10. Decisions for the operator

- **D1: web reachability.** The instance is exposed on the LAN today with no
  auth (§1.5). Recommended: bind to loopback (phase 0) and use Tailscale Serve
  for the phone. The alternatives are loopback only (Telegram as the only
  remote), or leaving it on the LAN, which I'd advise against. **This one is
  urgent whatever happens to the rest of the plan.**
- **D2: remove the admin chat outright?** Recommended: yes (phases 4 and 5).
  Its last use was 2026-07-29, it is wedged in one workspace, and it runs with
  write access its own policy file says it shouldn't have.
- **D3: which events to push.** Recommended: done, blocked, failed, waiting at
  a prompt, session died, and launch failed. Anything noisier gets muted with
  `notify_events`.
- **D4: routing model.** Recommended: reply-to plus focus now, and per-run
  topics revisited later. Say so if you want topics from the start (that
  means a supergroup with the bot as admin).
- **D5: an agent layer anywhere?** Recommended: none in Rails. Optionally,
  later, expose pane and send on `/mcp/admin` so your own Claude Code session
  can drive runs.
- **D6: an extra lock on the bot** (PIN or `/unlock`)? Recommended: no. The
  allow-list, private chats only and signed confirmations are enough for a
  single operator.
- **D7: Telegram as a third party.** Pane text and checkpoints will pass
  through Telegram's servers. That's accepted as the price of phone access
  unless you say otherwise.

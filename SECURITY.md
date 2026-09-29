# Security

workflow-orchestrator is a single-operator tool that runs on your own machine and starts coding agents with full access to your repositories. Read this before you run it, and before you reach it from anywhere other than that machine.

## Threat model

**What it does.** It runs one Rails app, the web UI plus two MCP endpoints, on your machine. From it you queue *runs*. Each run opens an interactive `claude`, `codex` or `opencode` session in a git worktree of one of your registered repositories. Anyone who can queue a run can get code of their choosing executed on your machine, as you. Everything below follows from that.

**No authentication.** The web UI and `/mcp/admin` have no login, no API key and no user accounts. That is deliberate: the only intended user is the person at the keyboard. `/mcp/run` is the one authenticated surface. Each session gets its own bearer capability, which stops working when the session ends.

**Loopback only.** What keeps other people out is where the app listens and which names it answers to:

- `bin/production` (and so `bin/service`) binds Puma to `127.0.0.1`. `bin/dev` binds to `localhost`. Nothing else on your network can connect.
- In production the app answers only requests whose `Host` is `localhost`, `127.0.0.1` or `[::1]` (any port). Any other name gets a `403`, and that includes `/up`. This is Rails' host authorization (`config.hosts`, built by `lib/workflow_allowed_hosts.rb`). It stops **DNS rebinding**, where a web page you visit points its own hostname at `127.0.0.1` so that it becomes same-origin with this UI and can read pages and submit forms. The MCP endpoints run the same check again through the `mcp` gem's `dns_rebinding_protection`, which also rejects a foreign `Origin`.
- Forms are protected by Rails' CSRF tokens, with an `Origin` check (on by default). Action Cable accepts same-origin connections only.

Two settings widen this. Use them only if you really mean to reach the app from somewhere else:

- `BINDING=0.0.0.0` (or `bin/production -b ...`) listens on other interfaces.
- `WORKFLOW_ALLOWED_HOSTS=name1,name2` (comma-separated, `config.hosts` syntax, so a leading `.` also allows subdomains) accepts further `Host` names, for example a reverse proxy or a tailnet name. The host of `WORKFLOW_RAILS_URL`, the URL sessions use to reach `/mcp`, is accepted automatically.

If you do either, whatever sits in front of the app has to provide the authentication. The app has none. Anyone who can reach it can run code as you.

**Agents run with approvals bypassed.** Sessions start with `--permission-mode bypassPermissions` (claude), `-s danger-full-access` (codex) or `--auto` (opencode). There is no sandbox around a session: it can read and write anything your user account can, run any command, and use the network. The worktree is its working directory, not a boundary. Treat a run's task text, and anything the agent reads while working on it (issues, web pages, dependencies), as input that can steer an agent holding your privileges. That is the usual prompt-injection risk of autonomous coding agents, and this tool does not reduce it.

**The app can edit itself.** Its own repository can be registered as a workspace. A run can then change the orchestrator's code, and a session can merge into `main` when asked, with no separate review step. `main` is what `bin/service` runs. A bad or malicious change to this repository reaches the running instance the next time it reloads or restarts.

**Remote control (Telegram).** If you configure a bot token, the app long-polls Telegram and accepts commands (list sessions, read their panes, type into them) only from the numeric user IDs in `TELEGRAM_ALLOWED_USER_IDS` / `telegram.allowed_user_ids`. It stays off unless both a token and an allow-list are set. Anyone on that list, and anyone who controls one of those Telegram accounts, can drive your sessions, so keep the list short. The bot token is a credential: whoever holds it can read the messages you send the bot.

**GitHub credentials.** Sessions push with a GitHub App installation token when one is configured (`GITHUB_APP_SETUP.md`). The token is short-lived (about an hour) and limited to the permissions you gave the App (Contents, plus Pull requests if you allowed it). It covers every repository the installation was granted, not only the run's repository, so install the App on the repositories you manage with this tool and no others. Without a GitHub App, a session falls back to your own `gh auth token`, which carries everything your GitHub account can do.

**Secrets on disk.** `config/master.key`, `config/credentials.yml.enc`, the SQLite databases under `storage/` and the logs under `log/` hold credentials and run content (prompts, reports, pane text). They are only as private as your user account.

## In scope

Reports are welcome for anything that lets someone **other than the operator** act through the app, or that breaks one of the guarantees above. For example:

- reaching the UI, `/mcp/admin`, `/mcp/run` or `/cable` from another origin or host while the default loopback-only configuration is in place (DNS rebinding, CSRF, cross-site WebSocket, a `Host`/`Origin` check bypass);
- using a run session's `/mcp/run` capability after its session has ended, or to act as a different session;
- a Telegram user who is not on the allow-list getting the bot to do anything;
- an MCP tool that exposes more than it is documented to (arbitrary SQL, file reads, command execution);
- a sandbox instance (`bin/sandbox`, `WORKFLOW_SANDBOX=1`) reaching outside itself: the operator's herdr, Telegram, GitHub tokens, or paths outside its root;
- credentials or tokens leaking into logs, pages, prompts or anywhere else they don't belong.

## Out of scope

These are how the tool is meant to work, not vulnerabilities:

- An agent session doing something harmful with the access it is deliberately given, including after reading a malicious issue, web page or dependency. You choose which repositories to register and which tasks to run.
- Anything done by someone who can already run code as your user on the machine, or who can reach the app because you set `BINDING` or `WORKFLOW_ALLOWED_HOSTS` without putting authentication in front of it.
- The absence of authentication, multi-user support or per-user permissions.
- Issues in the agent CLIs (`claude`, `codex`, `opencode`), herdr, Telegram or GitHub themselves. Please report those to their maintainers.
- Denial of service against a local, single-user process.

## Reporting a vulnerability

Please report privately through GitHub's private vulnerability reporting: open this repository's **Security** tab and choose **Report a vulnerability**. Do not open a public issue, pull request or discussion for a security problem.

Include what you found, the version or commit you tested, steps to reproduce, and what an attacker gains. We will acknowledge the report, keep you updated while we work on a fix, and credit you in the advisory if you would like to be credited.

## Supported versions

Only the latest commit on `main` is supported. Fixes land there, and there are no maintained release branches.

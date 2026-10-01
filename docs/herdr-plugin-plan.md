# Paneyard as a herdr plugin

Status: implemented on `paneyard/goal-turn-paneyard-into-a-herdr-plugin-someone-w-df91`. This is the plan the
implementation followed, with the facts it rests on. Where the build changed the plan, the plan was updated.

## Goal

Someone who already uses herdr runs

```sh
herdr plugin install <owner>/paneyard
```

and from then on uses Paneyard from inside herdr: a keybinding queues a task for the repository they are
looking at, another lists runs and shows reports, a third closes a run's session. They never see `bin/setup`,
`bin/service`, `bin/rails credentials:edit`, a port number, or an SQLite path. The web UI is still there, one
action away, for the things a terminal is bad at (the layout editor, workspace settings).

The manual Rails route (`bin/setup`, `bin/service`) keeps working unchanged for contributors and for anyone
who prefers it.

## What herdr 0.7.5 gives a plugin (checked locally, not only in the docs)

- `herdr --version` here is **0.7.5**. Everything below works on it, and nothing needs more than the 0.7.0
  plugin API, so the manifest says `min_herdr_version = "0.7.0"`. (0.7.3 kept plugins per named session; from
  0.7.4 they are global to the user. Paneyard works either way, since it keeps its own state.)
- Manifest commands are argv arrays, never run through a shell. Runtime commands run with the plugin root as
  their working directory and **the herdr server's environment**, not the invoking client's: an action
  invoked from inside a run session's pane did not see that pane's variables. `PATH` is whatever the server
  was started with (here it includes asdf shims).
- Injected: `HERDR_SOCKET_PATH`, `HERDR_BIN_PATH`, `HERDR_PLUGIN_ID`, `HERDR_PLUGIN_ROOT`,
  `HERDR_PLUGIN_CONFIG_DIR` (`~/.config/herdr/plugins/config/<id>`), `HERDR_PLUGIN_STATE_DIR`
  (`~/.local/state/herdr/plugins/<id>`), `HERDR_WORKSPACE_ID`/`TAB_ID`/`PANE_ID`, and
  `HERDR_PLUGIN_CONTEXT_JSON`. For a workspace action the context looks like:

  ```json
  {"workspace_id":"w2M","workspace_label":"…","workspace_cwd":"/path/to/repo/main",
   "tab_id":"w2M:t1","focused_pane_id":"w2M:p1","focused_pane_cwd":"/path/to/repo/main",
   "focused_pane_agent":"claude","focused_pane_status":"working","invocation_source":"cli"}
  ```

  `workspace_cwd`/`focused_pane_cwd` are what "queue a task *here*" needs.
- `herdr plugin action invoke <id> --plugin <plugin>` is **asynchronous**: it returns `status: running`, and
  the command's stdout/stderr only appear later in `herdr plugin log list`. An action is therefore not a way
  to show the user anything; a popup pane is.
- `[[startup]]` runs once per herdr server start (and on live handoff), **not** on `plugin install`/`link`
  or `enable`. So the daemon must also be started lazily by every action, or a freshly installed plugin
  would do nothing until herdr restarts.
- `[[build]]` runs only on `plugin install` (never on `link`), without any herdr env.
- Keybindings are the user's own `[[keys.command]] type = "plugin_action"` entries in herdr's
  `config.toml`; a plugin cannot declare them. The README gives a block to paste.
- `herdr plugin pane open --plugin <id> --entrypoint <pane> [--placement …]` opens a manifest pane. A popup
  is session-modal, gets all input, and closes when its command exits.
- `herdr workspace focus <id>` and `herdr notification show <title> --body …` exist, so a popup can jump
  to a run's herdr workspace, and a non-interactive action can still tell the user something.

## 1. Packaging and lifecycle

### Ruby and gems: decision

Paneyard needs Ruby at the version in `.ruby-version` (4.0) and its gems. The options:

| Option | Friction for the user | Cost |
| --- | --- | --- |
| **A. The user's Ruby, gems vendored into the plugin checkout** (`bundle install` with `path vendor/bundle`, in `[[build]]`) | Needs a Ruby 4.0 somewhere on the machine. Install is a normal `bundle install`: sqlite3, nokogiri and commonmarker come prebuilt for darwin and linux, and the rest (puma, bootsnap, msgpack, nio4r…) compile small C extensions, which needs a C compiler (Xcode command-line tools on macOS). | None beyond what exists. |
| B. Ship or build a private Ruby inside the plugin (ruby-build in `[[build]]`, or a portable Ruby tarball per platform) | None if it works. | `ruby-build` compiles for several minutes and needs a C toolchain and openssl/libyaml headers, which is *more* friction for a user without them. Portable Ruby tarballs mean hosting and signing release artifacts per platform and keeping them in step with `.ruby-version`. |
| C. A container | Docker, and herdr/git/agent CLIs from inside it | Wrong shape: the runner has to drive the operator's own herdr, git checkouts and agent CLIs. |

**Picked: A.** It is the only option that adds no new moving part, and Ruby 4.0 is one `mise use -g
ruby@4.0` / `brew install ruby` away. To keep the friction as low as A allows:

- The entry point (`bin/herdr-plugin`, POSIX `sh`) **finds** a suitable Ruby instead of trusting `ruby` on
  the server's `PATH`: `PANEYARD_RUBY` (from the plugin's `.env`), then the Ruby the build used, then `ruby`
  on `PATH`, then the usual version-manager and Homebrew locations (asdf, mise, rbenv, chruby,
  `/opt/homebrew/opt/ruby`, `/usr/local/opt/ruby`). The first one at least `.ruby-version`'s major.minor
  wins. If none is found it fails with one message saying which Ruby to install and how to point
  `PANEYARD_RUBY` at one.
- `[[build]]` runs `bundle install` against that Ruby into `vendor/bundle` inside the managed checkout,
  without the development and test groups, and records the interpreter in `.paneyard-ruby` (gitignored),
  because gems with native extensions only work under the Ruby that built them. Gems belong to that exact
  checkout and lockfile, so the plugin root (not the state dir) is the right place for them: a reinstall
  replaces both together.
- The daemon runs with that Ruby's `bin` directory first on `PATH`, so `bin/production`'s `bundle` and
  `./bin/rails` (`#!/usr/bin/env ruby`) use the same interpreter. This does not reach agent sessions: herdr
  panes never inherit the Rails process's environment (`Runner::ProcessEnv`).
- `herdr plugin link <checkout>` runs no build, so a linked development checkout uses the bundle the
  contributor already has (`bin/setup`). The build's `bundle config --local` is never written into a
  contributor's checkout.

Open question for the operator: whether Ruby 3.4 is good enough (it would widen who can install without a
version manager). Nothing here has been run on it; relaxing the check is one line once CI covers it.

### Repo layout

`herdr-plugin.toml` at the **repository root**. The plugin *is* the app: `bin/production`, `db/`, `app/`
all have to be in the managed checkout, and a subdirectory manifest would still need the whole repository
cloned. So `herdr plugin install <owner>/paneyard` installs the repository, and the marketplace finds it
once the repository has the `herdr-plugin` topic.

Plugin-only code:

- `herdr-plugin.toml`
- `bin/herdr-plugin` — the `sh` entry point every manifest command goes through: finds Ruby, then runs
  `lib/paneyard_plugin/cli.rb` with it (stdlib only: no Bundler, no Rails, so an action answers in well
  under a second when the daemon is already up).
- `lib/paneyard_plugin.rb`, `lib/paneyard_plugin/*.rb` — plain Ruby like `lib/paneyard_sandbox`, ignored by
  Rails' autoloader: `Paths`, `EnvFile`, `Secrets`, `Daemon`, `Client`, `WorkspaceMatch`, `Cli`.

`platforms = ["macos", "linux"]`. macOS is what is tested; Linux has no known macOS-only code (the browser
opener uses `xdg-open` there) and the lockfile carries linux platforms. Windows is out: herdr panes there,
and Paneyard's process handling, are Unix-only.

### Daemon (`[[startup]]` and every action)

`PaneyardPlugin::Daemon` (modelled on `bin/service` and `PaneyardSandbox::Instance`, which stay as they are)
starts **this checkout's `bin/production`** as a detached process group, so Puma + Solid Queue, `db:prepare`
on every start (migrations), and the recurring schedule all behave exactly as under `bin/service`.

- **Idempotent and race-safe.** Start takes an exclusive `flock` on `state/daemon.lock`, so two startup hooks
  (two herdr sessions, or a startup hook racing an action) cannot start two servers. Under the lock: if the
  recorded pid is alive and `/up` answers, do nothing; if it is alive but still booting, wait for it.
- **State lives in `HERDR_PLUGIN_STATE_DIR`:**

  | Path | What |
  | --- | --- |
  | `storage/production*.sqlite3` | the databases (`PANEYARD_STORAGE_DIR`, already honoured by `config/database.yml`) |
  | `run_sessions/` | each session's MCP config and prompt (new `PANEYARD_RUNTIME_DIR`; was `tmp/run_sessions` in the app root, which a reinstall would wipe under a live session) |
  | `log/paneyard.log` | the daemon's stdout/stderr (production logs to stdout) |
  | `secret_key_base` | generated on first start, mode 0600 |
  | `daemon.json` | pid, port, herdr socket, code fingerprint, start time |
  | `port` | the chosen port, kept across restarts |
  | `puma.pid` | Puma's pidfile (`PIDFILE`), so it never lands in the checkout's `tmp/pids` |

  Rails' `tmp/` (bootsnap cache) stays in the plugin root: it is a cache, safe to lose on reinstall.
- **Secrets.** `SECRET_KEY_BASE` comes from `state/secret_key_base`, generated with
  `SecureRandom.hex(64)` the first time and reused after. Nothing else in the app needs credentials: every
  credentials lookup (Telegram, GitHub App) already prefers an environment variable, so the `.env` covers
  them. A `SECRET_KEY_BASE` in the `.env` wins, for someone moving an existing instance over.
- **Port.** The first start picks a free loopback port and writes it to `state/port`; later starts reuse it,
  so a URL registered with Claude Code keeps working. If something else has taken it by then, a new free one
  is picked, written back, and a herdr notification says the MCP registration needs updating (the `mcp`
  pane re-registers in one key). `PORT` in the `.env` pins it instead. A unix socket was considered: neither
  browsers nor `claude mcp add --transport http` speak HTTP over a unix socket, so it would need a proxy.
  Binding stays `127.0.0.1` and `config.hosts` stays loopback-only (`SECURITY.md`).
- **herdr socket.** The daemon gets the `HERDR_SOCKET_PATH` herdr handed the plugin (`Runner::Herdr` already
  prefers that variable over `~/.config/herdr/herdr.sock`). It is recorded in `daemon.json`. A startup hook
  from a *different* herdr server (a named session with its own socket) finds the daemon up on the other
  socket and leaves it alone with a log line: restarting it there would make reconcile treat every live
  session on the first server as lost. One Paneyard per user, following the herdr server that started it;
  `restart` moves it deliberately.
- **Upgrades.** `daemon.json` records a fingerprint of the code it runs (manifest `version`, plugin root,
  `Gemfile.lock` digest). An action that finds a running daemon with a different fingerprint restarts it.
  `herdr plugin install <owner>/paneyard` again (optionally `--ref`) replaces the managed checkout and
  rebuilds its gems; the next action, or the next herdr start, restarts the daemon on the new code, and
  `bin/production` migrates the database on that start. A restart is harmless to running sessions: herdr
  owns their processes, exactly as with `bin/service restart`.
- **Environment hygiene.** The daemon is spawned with `BUNDLE_*`, `RUBYOPT`, `GEM_*`, `RAILS_ENV`,
  `PANEYARD_SANDBOX*`, and a run session's `PANEYARD_RUN_*` removed, and then the plugin's own values set:
  `RAILS_ENV=production`, `PORT`, `BINDING=127.0.0.1`, `PANEYARD_RAILS_URL`, `PANEYARD_STORAGE_DIR`,
  `PANEYARD_RUNTIME_DIR`, `PIDFILE`, `HERDR_SOCKET_PATH`, `SECRET_KEY_BASE`.

None of this touches `bin/dev`, `bin/sandbox`, `bin/preflight` or `bin/service`: they do not set the new
variables, so the app behaves exactly as before for them.

### One Paneyard per machine

Two instances that both register the same repository will remove each other's fresh worktrees: the
janitor treats a clean worktree that its own database does not know as an orphan
(`Orchestrator::WorktreeJanitor.in_use`). The plugin is a second instance with its own database, so:
**someone already running `bin/service` should stop it before using the plugin**, or keep the two on
different repositories. The README says so, and says how to move the data over (stop `bin/service`, copy
`storage/production*.sqlite3` into the plugin's `storage/`). Not automated: it is a one-off, and an
automatic migration that guessed wrong would lose the operator's history.

## 2. HERDR_SOCKET_PATH

Already honoured: `Orchestrator::Runner::Herdr.socket_path` prefers `ENV["HERDR_SOCKET_PATH"]` and only falls
back to `~/.config/herdr/herdr.sock`. The daemon is started with the path herdr gave the plugin, so nothing
in the app changes. The sandbox guard (`Orchestrator::Sandbox`) is untouched.

## 3. Config

`HERDR_PLUGIN_CONFIG_DIR/.env` — print the directory with `herdr plugin config-dir paneyard`. On first start
the plugin writes a commented sample (only if no `.env` exists, never overwriting) listing what is
configurable: `PANEYARD_MAX_CONCURRENT_RUNS`, `PANEYARD_CLAUDE_MODEL`/`CODEX`/`OPENCODE`, `TELEGRAM_*`,
`GITHUB_APP_*`, `PORT`, `PANEYARD_RUBY`. The format is dotenv: `KEY=value`, optional `export`, `#` comments,
single or double quotes, and double-quoted values may span lines (a GitHub App private key). Every key is
passed to the daemon except the few the plugin owns (`RAILS_ENV`, `HERDR_SOCKET_PATH`, `PIDFILE`,
`PANEYARD_STORAGE_DIR`, `PANEYARD_RUNTIME_DIR`, `PANEYARD_RAILS_URL`, `BINDING`, `PANEYARD_SANDBOX*`,
`PANEYARD_HOT_RELOAD`), which are ignored with a log line. The `.env` is read at daemon start; the
**Restart** action applies a change (the fingerprint includes the `.env`'s digest, so the next action after
an edit also restarts).

## 4. User surface inside herdr

Every action first makes sure the daemon is up (starting it if needed, which takes a few seconds the first
time), then does its one thing. Interactive ones open a popup pane, because action output is invisible.

| Action (`paneyard.<id>`) | Context | What it does |
| --- | --- | --- |
| `queue` — Queue a task here | workspace | Opens the **queue** popup for the focused pane's directory. |
| `runs` — Runs | workspace | Opens the **runs** popup: every run across workspaces, newest first. Select one to read its newest report, jump to its herdr workspace, close its session, or open it in the browser. |
| `report` — Show this run's report | workspace | In a run's herdr workspace: opens the runs popup on that run's report. |
| `close` — Close this run's session | workspace | In a run's herdr workspace: asks for confirmation in a popup, then closes the session (kills the CLI, closes the herdr workspace, frees the slot, removes the worktree if its work is saved) — the run screen's **Close session**. |
| `open` — Open Paneyard in the browser | workspace | Opens the web UI (the run's page when invoked in a run's workspace). |
| `mcp` — Connect Claude Code | workspace | Opens a popup with the `/mcp/admin` URL and the `claude mcp add` line, and offers to run it (replacing a stale `paneyard` registration). |
| `mcp-url` — Print the MCP URL | — | Prints the URL to the plugin log and shows it as a herdr notification, for scripts and for the user. |
| `restart` — Restart Paneyard | — | Applies a `.env` change or a reinstall. |
| `stop` — Stop Paneyard | — | Stops the daemon (before uninstalling, say). |

"In a run's herdr workspace" is decided by matching `HERDR_WORKSPACE_ID` against the session's recorded
herdr workspace id (added to the MCP run summary), falling back to the focused pane's directory being inside
the run's worktree.

**Queue popup.** Resolves the focused pane's directory to a registered workspace: a workspace matches when
the directory is its `main` checkout or anything beside it under its root (that includes run worktrees).
If none matches, it registers one through the existing `register_workspace` tool (the same
`Orchestrator::WorkspaceRegistration` checks the web UI uses), named after the root directory, and shows the
problems and their fixes if the layout is wrong — nothing on disk is changed. Then it reads the task (a
blank line submits; Ctrl-C cancels), asks for the driver (Enter for `claude`), queues it, and shows the run
id and the queue position. The run's herdr workspace opens on its own when a slot frees, as today.

**Runs popup.** A numbered list (run id's last four characters, status and herdr's agent state, driver,
workspace, first line of the task), newest first; Enter refreshes. A number selects a run and shows its
newest checkpoint report, through `less` when it is longer than the popup. From there: `f` focus its herdr
workspace, `c` close its session (with confirmation), `o` open its page, `b` back, `q` quit. A thin client
over `/mcp/admin` (the existing `PaneyardSandbox::McpClient`), stdlib Ruby, no new gems.

Suggested keybindings (README):

```toml
[[keys.command]]
key = "prefix+q"
type = "plugin_action"
command = "paneyard.queue"
description = "paneyard: queue a task here"
```

…and the same for `paneyard.runs` and `paneyard.close`.

### Considered and left out

- **`[[events]]`.** `workspace.closed` would let Paneyard notice a run's herdr workspace being closed by hand
  immediately, but `RunSessionReconcileJob` already does that within about 30 seconds, and an event hook
  would need an endpoint that trusts herdr's event payload to end sessions. `worktree.created` is herdr's own
  worktree feature, unrelated to Paneyard's worktrees. Not worth it now.
- **`[[link_handlers]]`.** Paneyard's own URLs rarely appear in panes, and with a per-user port a pattern
  would also match a contributor's `bin/dev` or `bin/sandbox` URLs.
- **Sending a message to a session from a popup.** The session is a herdr pane; typing into it directly is
  the better interface.

### New Rails surface (small, in the existing style)

- `close_session` admin-only MCP tool. The plugin needs to close a session without a browser, the web form
  is CSRF-protected, and an operator's own Claude Code can use it too. Like `register_workspace` it is the
  operator's decision, so it is not on `/mcp/run`. The controller's logic moves into
  `Orchestrator::SessionClose` so the button and the tool cannot drift.
- The MCP run summary gains the session's `herdr_workspace` id (what the plugin matches on), and
  `list_workspaces` gains each workspace's `id` (the web UI's URLs use it, for "open this run's page").
- `PANEYARD_RUNTIME_DIR` for `Runner::Local`'s runtime root (default unchanged).

## 5. MCP registration

The URL is `http://127.0.0.1:<port>/mcp/admin`, with the port kept stable across restarts (above). Three
ways to get at it: the `mcp` popup (shows it and runs `claude mcp remove -s user paneyard` then
`claude mcp add --transport http -s user paneyard <url>` on a keypress), `herdr plugin action invoke
paneyard.mcp-url --plugin paneyard` (notification + plugin log), and `state/url` for scripts. If the port
ever has to change, the startup log and a notification say so.

## 6. Upgrade story

`herdr plugin install <owner>/paneyard` again (or `--ref <tag>`) replaces the checkout and rebuilds gems.
The next action or herdr start restarts the daemon (fingerprint changed) and `bin/production`'s
`db:prepare` migrates. State and config are outside the checkout, so they survive. `herdr plugin uninstall
paneyard` after `paneyard.stop` removes it; the state directory is left in place, as herdr leaves it.

## Verification

What was run, and what it showed (on the operator's machine, herdr 0.7.5, Ruby 4.0.1):

- **Specs.** `spec/lib/paneyard_plugin/` (paths, the `.env` parser and reserved keys, the sample, secret
  generation, reuse and a four-way race, the daemon against a real stand-in process: second start reuses it,
  four racing callers start one, the port is kept and re-picked when taken, a pinned `PORT`, a `.env` edit
  restarts, another herdr socket is left alone and `restart` moves it, stale and reused pids, stop, a crash
  while starting; the popups' conversations against a stand-in client), plus `close_session`,
  `Orchestrator::SessionClose`, the admin endpoint's tool list and the existing close-session request spec.
- **The real app through the plugin CLI, outside herdr** (scratch state, a herdr socket that does not exist):
  boots in about six seconds with no credentials, all state in the state dir, a second `start` reuses it;
  the queue flow registered a scratch repository from a directory deep inside its `main`, matched a run
  worktree path the second time, rejected a bad driver, and showed `register_workspace`'s fixes for a plain
  clone; the runs list and run screen rendered.
- **The install build, simulated** on a copy of the checkout (a managed install needs the repository on
  GitHub): `bin/herdr-plugin build` installed the bundle into `vendor/bundle` in 34 seconds without
  touching `Gemfile.lock`, and the copy then booted from that bundle under a `PATH` whose only Ruby was
  macOS's 2.6, by finding the build's Ruby. With no suitable Ruby, the entry point says what to install.
- **In the real herdr**, with this worktree linked: the manifest linked without warnings; the first
  `paneyard.mcp-url` started the daemon (port 49573, state in `~/.local/state/herdr/plugins/paneyard`,
  herdr's own socket), the second reused it; the queue pane, opened as a tab in a scratch herdr workspace so
  it could be typed into, registered and queued; the run opened its own herdr workspace and its Claude Code
  session reported `done` (the first attempt stopped at Claude Code's folder-trust prompt for the new
  directory, which Paneyard's launch diagnosis named); the report pane and then the close pane, opened inside
  the run's herdr workspace, showed that run's report and closed its session, which completed the run,
  closed its herdr workspace and removed its clean worktree; `paneyard.restart` and a `.env` edit each
  restarted on the same port; the `mcp` pane showed the URL and command (declined, so Claude Code's config
  was not changed); `paneyard.stop` stopped every process; `herdr plugin log list` stayed clean. Then
  unlinked, and the test state removed. The running `bin/service` instance on 7263 kept answering throughout.
- **Not exercised live:** the `[[startup]]` hook itself (it runs only when a herdr server starts, and the
  operator's was not restarted; it runs the same `ensure_running` as every action), the popup placement
  (opening one would have put a modal over the operator's screen; the same panes were driven as tabs), the
  `open` action (it opens a browser), and `herdr plugin install` from GitHub.

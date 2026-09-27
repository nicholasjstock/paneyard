# Per-workspace layouts (design, not yet implemented)

Status: proposal. Nothing here exists in code yet.

## Problem

A run's herdr workspace opens with two panes, hardcoded in
`Orchestrator::RunSessionRunner.start!`:

1. `Herdr.workspace_create` gives the **agent pane** (its root pane). That pane
   gets the full session env (`SessionEnv.for_session`) and runs the
   claude/codex/opencode CLI. Its id is `RunSession#herdr_pane_id`.
2. `open_editor_pane` splits it `right` and types `nvim .` into the new shell,
   provided `nvim` is on Rails' PATH. Rails never records this pane.

Every workspace gets that same layout. We want the layout to be defined per
`Workspace`: the agent pane stays and stays primary, but nvim might go in a
tab instead of a split, and some projects want more panes (`bin/dev`,
`tail -f log/development.log`, a test watcher).

This is **pane setup at session start and nothing else**. Rails opens the
panes, types a command into each one, and forgets about them. It does not
watch, restart, health-check or wait on them. "Rails schedules, it does not
orchestrate" still holds: this is the herdr version of a tmuxinator file, not
a process supervisor.

## 1. What herdr supports

All checked against herdr 0.7.5 (protocol 17) with `herdr api schema --json`
and the herdr socket-API docs. The live checks were **read-only**
(`workspace.get`, `tab.list`, `pane.list`, `layout.export`,
`pane.process_info`, `ps`) and ran against this run's own workspace. Nothing
was created or closed.

| Capability | herdr surface | Notes |
|---|---|---|
| Split a pane | `pane.split {target_pane_id, direction: right\|down, ratio?, cwd?, env?, focus?}` -> `{pane}` | Already used. **`ratio` and `env` exist in the schema, but our client passes neither.** |
| New tab in a workspace | `tab.create {workspace_id, label?, cwd?, env?, focus?}` | Not in our client yet. Starts with one shell pane. |
| Declarative tree | `layout.apply {workspace_id \| tab_id, root: LayoutNode, tab_label?, focus?}` | `LayoutNode` is either `pane {label, cwd, env, command: argv[]}` or `split {direction, ratio, first, second}`. Per the docs it **creates a fresh tab**. When given `tab_id`, it replaces that tab and "does not preserve live PTYs … or running processes". |
| Read a layout | `layout.export {tab_id \| pane_id}` | Live result for this run: `split right 0.5 { pane w1F:p1, pane w1F:p2 }` with cwd only. It reports no command and no label, because we set neither. |
| Pane names | `pane.rename {pane_id, label}`, `tab.rename {tab_id, label}`, `label` on `workspace.create`/`tab.create`/layout nodes | Today panes have no label and the tab label is `"1"`. |
| Focus | `focus` flag on create/split/apply, plus `pane.focus`, `tab.focus`, `workspace.focus` | We create the workspace with `focus: false` so a run never takes over the operator's screen. That has to stay. |
| cwd | `cwd` on every creating call | We always pass the worktree. |
| env | `env` map on `workspace.create`, `tab.create`, `pane.split`, layout pane nodes | herdr always injects `HERDR_*` itself and wins any conflict with them. |
| Run a command | none on `pane.split` or `tab.create`. We type it into the shell with `pane.send_input {text, keys: ["Enter"]}`. `layout.apply` pane nodes and `herdr pane run` take argv. | typeahead during rc-file startup was confirmed to work in earlier live testing (see `Herdr` header). |
| Teardown | `workspace.close`, `tab.close`, `pane.close` | Previously confirmed live: `workspace.close` closes every pane in the workspace and the processes in them. |

**Found live, relevant to this design: split panes do not inherit the
workspace's env.** The env passed to `workspace.create` applies to the root
pane only. This run's agent pane has `WORKFLOW_RUN_ID`, `WORKFLOW_RUN_TOKEN`
and `GH_TOKEN`. Its `nvim .` split (`ps eww` on the nvim pid) has only the
herdr-injected `HERDR_*` values. Every extra pane therefore gets exactly the
env we pass it and nothing else. That is useful: the capability token and the
GitHub token stay in the agent pane unless we choose to hand them out.

Still unverified. Checking these needs mutating calls, so they must be run
live against a throwaway workspace during implementation, not in a spec:

- Whether a `tab.create`d tab is also closed by `workspace.close`. This is
  almost certain, but it is load-bearing for lifecycle, so verify it.
- What `layout.apply`'s `command` argv does: exec it directly or run it
  through the shell, and whether the pane closes, freezes or drops to a shell
  when the command exits.
- Whether `tab.create {focus: false}` in an unfocused workspace leaves the
  active tab alone.
- Whether processes that ignore SIGHUP or daemonise survive `workspace.close`.
  `bin/dev` (foreman/overmind) should die with its pty; a double-forking
  server would not. That is the project's problem, but document it.

## 2. Where the layout lives

**Recommendation: one operator-owned column on `Workspace`, `layout` (text,
nullable, YAML), edited on the existing workspace edit form. No repo file in
v1.**

The repo file (`.orchestrator/layout.yml`), rejected for v1:

- **It doesn't actually travel with the branch.** A run's worktree is cut from
  `main` at provisioning, so a new run always reads `main`'s copy. A branch's
  own edits could only affect a `--resume` of that same run, which is an odd
  place for a layout change to take effect.
- **A run can rewrite it.** Sessions have full access and may merge straight
  into `main` with no review gate. Layout commands execute automatically in the
  operator's terminal at the start of every later run, before any human or
  agent has looked at the checkout. A session could already edit `bin/dev`, so
  this is no new privilege. It is a new *automatic trigger*, though, and it
  fires on unrelated future runs. For target repos with other collaborators it
  also means their commits choose what runs in the operator's panes.
- **Target repos are unrelated projects.** They would all have to carry an
  orchestrator-specific dotfile. Some of these repos are shared, and nobody
  else there runs this tool.
- **Much of a layout is operator preference, not a project fact.** nvim in a
  tab or a split, extra panes at all: this depends on the person and machine,
  which is exactly what `Workspace` rows already represent.
- **Changing it would need a commit and a merge to `main`.** A column changes
  on the next run.

Both, with precedence (repo file overrides column, or the reverse): rejected.
Two sources with a merge rule is exactly the kind of cleverness this app has
been removing. It also keeps the problems of the repo file.

What the repo file would buy is versioning and sharing, and a project-specific
fact such as "the dev server is `bin/dev -p $PORT`" does sit naturally in the
repo. If that is missed later, the additive form is an **explicit, per-workspace
opt-in**, `layout_source: repo`, never auto-discovery. It would read the file
from the **source checkout (`main`)**, not the run's worktree, so a run cannot
change its own layout. Left as an open question.

## 3. Schema

Stored as YAML text, so the operator can keep comments. Parsed and validated
by a new `Orchestrator::WorkspaceLayout`, both on `Workspace` save (errors
appear on the edit form) and again at session start.

```yaml
# workspaces.layout -- the agent pane is implicit: always tab 1, pane 1,
# always herdr_pane_id, never listed here.
agent:
  tab: agent            # optional label for the agent's tab (default: herdr's)
panes:
  - name: editor
    command: nvim .
    placement: split    # split | tab
    of: agent           # pane to split; default: agent, or the tab's first pane
    direction: right    # right | down            (split only)
    ratio: 0.5          # 0.1..0.9, share kept by `of` (split only)
  - name: server
    command: bin/dev -p {{port}}
    placement: tab
    tab: server         # tab label; default: name
  - name: log
    command: tail -f log/development.log
    placement: split
    of: server
    direction: down
    focus: true         # the active pane of its own tab
  - name: specs
    command: bundle exec guard
    placement: tab
```

That produces:

```
tab "agent":  [ agent | editor ]
tab "server": [ server
                ------
                log (focused) ]
tab "specs":  [ specs ]
```

Rules:

- `name`: required, unique, `[a-z0-9_-]{1,32}`. `agent` is reserved. Becomes
  the herdr pane label (`pane.rename`).
- `command`: optional. With no command the pane is a plain shell. The command
  is **shell text typed into the pane** with `pane.send_input`, the mechanism
  already verified for nvim. It is not a `layout.apply` argv. That gives the
  operator's PATH, rc files, `&&` and `$VAR`, and when the command dies the
  pane falls back to a shell with the error on screen, where the operator can
  press ↑ Enter.
- `placement: split` requires `of` to name the agent or an **earlier** pane.
  The new pane lands in `of`'s tab. `placement: tab` opens a new tab. Panes are
  created in list order.
- `focus`: at most one per tab. It sets that tab's active pane. The agent's tab
  is always the workspace's active tab, and the workspace is always created
  unfocused. v1 has no way to open a run looking at a non-agent tab (open
  question).
- Size limits: 8 panes at most, `command` at most 1 KB.

**Interpolation.** `{{worktree}}`, `{{branch}}`, `{{run_id}}`,
`{{workspace}}` and `{{port}}` are substituted into `command`. Each value is
`Shellwords.escape`d because the command is shell text. An unknown `{{…}}` is
a validation error. The same values go into every extra pane's env as
`WORKFLOW_WORKTREE`, `WORKFLOW_BRANCH`, `WORKFLOW_RUN_ID`, `WORKFLOW_PORT` and
`PORT`, so a command can use `$PORT` instead, which is what `bin/dev` and
Procfiles already read.

**Ports.** A port is allocated only when the layout references `{{port}}`.
`Orchestrator::PortAllocator` picks the lowest port in `3100..3999` that meets
both conditions:

- it is not recorded on another **live** `RunSession` (new column
  `run_sessions.port`; it frees itself when `ended_at` is set)
- a bind probe on `127.0.0.1` succeeds

Four concurrent runs then never collide on 3000 or with each other. The agent
pane also gets `PORT`/`WORKFLOW_PORT` so the session can curl or restart its own
server, and the run screen shows `http://localhost:<port>`. One port per run in
v1. Named ports (`{{port.web}}`, `{{port.vite}}`) are an open question.

**Env for extra panes.** `WorkspaceEnvVars` (the recorded per-workspace
workarounds), plus `SessionEnv.sanitized_process_env`, plus the interpolation
variables above. Deliberately **not** the capability token (`WORKFLOW_RUN_TOKEN`),
the MCP config or `GH_TOKEN`: a log tail or dev server needs none of them.
Today's nvim pane already runs without them, as found above. That becomes a new
`SessionEnv.for_layout_pane(run:, vars:)`.

## 4. Lifecycle

The whole rule is: **extra panes live and die with the herdr workspace, and the
workspace lives and dies with the agent pane.** Rails does not track extra
panes individually.

- **Close session / Stop** (`RunSessionRunner.finish!`): unchanged. It already
  calls `workspace.close`, which takes every tab and pane down.
- **Agent CLI exits but its pane survives** (`refresh!` → `mark_process_lost!`
  → `finish!`): unchanged, and the workspace is closed.
- **Agent pane gone** (`refresh!` → `mark_pane_lost!`): **this needs a change.**
  Today it only kills the agent pid, because until now "pane gone" meant the
  whole workspace was gone. With a `server` tab, an operator who closes just the
  agent pane (or its tab) leaves a live workspace with `bin/dev` still bound to
  the port and cwd'd inside a worktree that `WorktreeJanitor.release!` is about
  to remove. `mark_pane_lost!` must call `close_herdr_workspace(session)` too.
  That is harmless when the workspace is already gone, since
  `workspace.close` is `request` rather than `request!` and its error is
  swallowed.
- **Reconcile keys off the agent pane only.** `RunSessionReconcileJob` and
  `refresh!` keep reading `herdr_pane_id` (agent pane) and `pid` (agent
  process group) and nothing else. So:
  - A crashed log tail or server drops to a shell or closes its pane. Rails
    never looks and the session stays live. Correct: the session is still
    there and the operator sees the dead pane.
  - A dead agent is noticed exactly as today, however many other panes are
    alive. The workspace then gets closed (above), so a live server cannot
    mask a dead session or outlive it.
  - `kill_process` still sends SIGTERM only to the agent's process group. The
    extra panes' processes go with `workspace.close`, as nvim's do today.
- **Janitor**: no change. It works on git worktrees, not panes. Because the
  workspace is closed before `release!` in both the Close session and the
  reconcile path, no layout process is left running inside a removed
  worktree.
- **Failure at start**: every extra pane is best effort, the same as
  `open_editor_pane` today. A herdr error while creating, renaming or typing
  into one pane is logged, that pane is skipped and the rest continue. It never
  fails the run. An agent-pane failure still fails the run and closes the
  workspace (the existing `rescue`).
- **Ordering**: extra panes are opened right after `workspace.create` and
  before `start_agent!`, where the editor split is today. That keeps the
  operator's first view complete, and their shells start up while the agent's
  shell is settling. Opening them after the agent pane has settled
  (`wait_for_available_shell!`) would slow start-up for no gain.
- **Resume** (`start!(resume_session_id:)`): a resumed session opens a new
  workspace, so it gets the layout fresh. It reuses the session's port if that
  port is still free, and otherwise allocates a new one.

## 5. Default and migration

`workspaces.layout` is `NULL` for every existing row, and `NULL` means
`WorkspaceLayout::DEFAULT`, the exact current behaviour:

```yaml
panes:
  - name: editor
    command: nvim .
    placement: split
    of: agent
    direction: right
```

It keeps one special case: the built-in default skips the editor pane when
`nvim` is not on PATH, as `open_editor_pane` does today. An operator-written
layout gets no PATH check. A missing command shows up as `command not found`
in its own pane, which is visible and harmless. An empty `panes: []` means
"agent pane only".

Migration steps, each shippable on its own:

1. Migration: `add_column :workspaces, :layout, :text` and
   `add_column :run_sessions, :port, :integer`. No backfill.
2. `WorkspaceLayout` (parse, validate, default, interpolate) and the new herdr
   client calls, with specs. Move `open_editor_pane` behind the layout, which
   produces the default. The pane then gets its `editor` label and the
   `WORKFLOW_*` env, and is otherwise unchanged.
3. `mark_pane_lost!` closes the workspace. Worth doing even before layouts
   land, because it is correct today too.
4. Workspace edit form: a `layout` textarea (prefilled with the default as a
   comment/example), with validation errors shown inline.
5. Ports: `PortAllocator`, `run_sessions.port`, and the port link on the run
   screen.

Sessions already running when this ships are not affected. Only new starts
read the layout. Rollback is `remove_column`: the code falls back to the
default.

## 6. Fit with CLAUDE.md / AGENTS.md

- **Scheduling, not orchestration**: layout is applied once, synchronously,
  inside `start!`. There is no job, no polling, no restart, no readiness wait
  (`pane.wait_for_output` is intentionally not used) and no state kept per
  extra pane.
- **herdr owns the processes**: we only create panes and type into them.
  Teardown is herdr's `workspace.close`.
- **MCP boundary**: no new tools. A session cannot read or change the layout
  through MCP. If it wants another process it can start one itself.
- **Workspace-first**: the config is a `Workspace` attribute, edited under
  `/workspaces/:id/edit`.

## Alternatives rejected

| Alternative | Why not |
|---|---|
| Repo file `.orchestrator/layout.yml` (alone, or with precedence) | See §2: read from `main` anyway, rewritable by runs with no review, pollutes unrelated repos, mostly operator preference. Possible later as an explicit opt-in read from `main`. |
| `layout.apply` for the whole thing | It creates a *new* tab, and with `tab_id` it replaces the tab and kills its PTYs. The agent pane comes from `workspace.create` and must survive, so the agent's tab can't be built this way. Its `command` argv exit semantics are also unverified, and it bypasses the operator's shell, which `bin/dev`-style commands need for PATH/rbenv. It could build *non-agent* tabs in one call later, once verified live. |
| Rails supervising extra panes (restart on crash, health checks, wait-for-ready before prompting the agent) | That is orchestration. A crashed server is visible in its pane, and the agent or operator restarts it. |
| Tracking extra pane ids on `RunSession` | Nothing needs them: `workspace.close` covers teardown, and reconcile must *not* look at them. |
| Giving extra panes the full session env | They would hold the MCP capability and `GH_TOKEN` for no reason. Found above that today's nvim split already runs without them. |
| Auto-detecting from `Procfile.dev`/`bin/dev` | Too magic, and one `bin/dev` pane (foreman multiplexes) already covers it explicitly. |
| JSON column with a structured form builder | The form would cost more than the feature. YAML text with validation is enough for one operator. |

## Files that would change

- `db/migrate/*_add_layout_to_workspaces.rb`, `*_add_port_to_run_sessions.rb`,
  and `db/schema.rb`
- `app/models/workspace.rb`: `validate :layout_is_valid`, and `#layout_config`
  returning the parsed layout or the default
- **new** `app/services/orchestrator/workspace_layout.rb`: parse, validate,
  `DEFAULT`, `interpolate(vars)` → plain `Pane` structs
- **new** `app/services/orchestrator/session_layout.rb`: `open!(run:,
  agent_pane:, workspace_id:, layout:, vars:)`. It walks the panes in order
  (`tab_create`/`pane_split` → `pane_rename` → `pane_send_input`), best effort
  per pane, and replaces `RunSessionRunner.open_editor_pane`.
- **new** `app/services/orchestrator/port_allocator.rb`
- `app/services/orchestrator/herdr.rb`: `pane_split(…, ratio:, env:)`,
  `tab_create`, `tab_rename`, `pane_rename`, plus documented header entries
- `app/services/orchestrator/run_session_runner.rb`: call `SessionLayout`,
  allocate the port, remove the `EDITOR_*` constants, and make `mark_pane_lost!`
  close the workspace
- `app/services/orchestrator/session_env.rb`: `for_layout_pane`, and
  `PORT`/`WORKFLOW_PORT` in `for_session`
- `app/controllers/workspaces_controller.rb`: permit `:layout` (both
  `workspace_params` and `workspace_edit_params`)
- `app/views/workspaces/{new,edit}.html.erb`: layout textarea and errors
- `app/views/runs/show.html.erb`: port link when `session.port`
- `AGENTS.md` / `CLAUDE.md`: a short "Layouts" note (agent pane is primary;
  reconcile ignores the rest; layout is start-time setup only), and a README
  mention

## Spec coverage the implementation needs

All with `Orchestrator::Herdr` stubbed. No live socket.

- `spec/services/orchestrator/workspace_layout_spec.rb`
  - `nil` → default equals today's editor split; `panes: []` → no extra panes
  - rejects: duplicate/reserved names, `of` naming a later or unknown pane,
    split fields on a tab pane, two `focus` in one tab, unknown `{{var}}`, bad
    ratio, too many panes, invalid YAML
  - interpolation shell-escapes values (a worktree path with a space and a `'`)
- `spec/services/orchestrator/session_layout_spec.rb`
  - issues `pane_split`/`tab_create`/`pane_rename`/`pane_send_input` in order
    with the right targets. A split `of: server` targets the pane id returned
    for `server`.
  - env passed to extra panes has `PORT`/`WORKFLOW_*` and **no**
    `WORKFLOW_RUN_TOKEN` or `GH_TOKEN`
  - a `Herdr::Error` on one pane logs, skips it and continues with the rest
  - never calls `workspace_focus`, and creates tabs with `focus: false`
  - default layout without nvim on PATH opens nothing (ported from the existing
    runner spec)
- `spec/services/orchestrator/run_session_runner_spec.rb`
  - `start!` applies the workspace's layout before `agent_start`, and
    `herdr_pane_id` is still the root pane
  - an extra-pane failure does not fail `start!`
  - `mark_pane_lost!` (via `refresh!` with `agent_get` raising `Herdr::Error`)
    now calls `workspace_close`
  - `start!` records `port` only when the layout uses `{{port}}`, and the agent
    env carries `PORT`
- `spec/services/orchestrator/port_allocator_spec.rb`: skips ports held by
  live sessions, reuses ports of ended sessions, and skips a port bound by a
  real `TCPServer` in the spec. That is a real socket on 127.0.0.1, not
  herdr's.
- `spec/jobs/run_session_reconcile_job_spec.rb`
  - agent pane alive while a (stubbed) extra pane is gone: session stays live
  - agent pane gone while the workspace still exists: session ends, run
    completes, `workspace_close` is called before `WorktreeJanitor.release!`
- `spec/models/workspace_spec.rb`: invalid layout blocks save with a readable
  error
- request/system spec: editing a workspace's layout round-trips the YAML text,
  and shows the validation error.

Manual live verification (operator's herdr, throwaway workspace), before
merging: the four unverified herdr behaviours in §1, and one real run with a
`bin/dev -p {{port}}` tab closed via Close session, then `lsof -i :<port>`
empty.

## Open questions for the operator

1. Repo file: agree to leave it out of v1? If it's wanted later, is
   "explicit opt-in, read from `main` only" the right shape?
2. Should a layout be able to make a non-agent tab active when you first
   switch to the run's workspace? (v1: no, agent tab always active.)
3. One port per run enough, or named ports (`web`, `vite`) from the start?
4. Should the editor pane also get `GH_TOKEN` so `git push` from nvim/shell
   works like the agent's? (Proposed: no, least privilege. Today it has
   neither.)
5. Port range `3100..3999`: any local services that collide on this machine?

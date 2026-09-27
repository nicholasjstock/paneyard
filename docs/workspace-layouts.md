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
- Whether `pane.split {env}` really sets the new pane's shell env. That is
  the only way to place the agent somewhere other than the first tab's root
  (§3), and it would carry the capability token.
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

The layout is a list of **tabs**. Each tab is a list of **panes**, and a tab
can hold any number of panes, arranged as any split tree. The workspace can
have any number of tabs. The one obligatory pane is the agent's: it must appear
exactly once, in the first tab. Everything else is optional, including the
editor. A layout that is only `tabs: [{panes: [agent]}]` gives a lone agent
pane.

```yaml
# workspaces.layout
tabs:
  - name: main                    # tab label (optional)
    panes:
      - agent                     # the obligatory agent pane; exactly once, first tab
      - name: editor
        command: nvim .
        split: { of: agent, direction: right, ratio: 0.5 }
      - name: shell               # no command: a plain shell in the worktree
        split: { of: editor, direction: down, ratio: 0.7 }
  - name: server
    panes:
      - name: server
        command: bin/dev -p {{port}}
      - name: log
        command: tail -f log/development.log
        split: { of: server, direction: down }
        focus: true
      - name: sidekiq-log
        command: tail -f log/sidekiq.log
        split: { of: log, direction: right }
  - name: specs
    panes:
      - name: specs
        command: bundle exec guard
```

That produces:

```
tab "main":   [ agent | editor ]
              [       | ------ ]
              [       | shell  ]
tab "server": [ server               ]
              [ -------------------- ]
              [ log (focused) | sidekiq-log ]
tab "specs":  [ specs ]
```

Why a list of splits rather than herdr's nested `first`/`second` tree: each
entry maps one-to-one onto the `pane.split` call that builds it, so any tree
herdr can hold can be written down in creation order. It also stays readable in
a textarea. Since herdr only splits `right` or `down`, where a pane sits in its
tab depends on the order it was split in, and the list order is that order.

Rules:

- **Tabs** are created in list order. The first tab comes from
  `workspace.create`, the others from `tab.create {focus: false}`. The first
  pane of a tab is its root and takes no `split`. Every later pane needs one.
  There is no limit on tabs or panes, beyond a sanity cap (e.g. 32 panes in
  total) so a typo can't open hundreds of shells.
- **`agent`**: a reserved bare entry. It must appear exactly once, and in the
  first tab, so the tab you land on is the agent's. It may be the tab's root
  or a split of another pane (`{agent: {split: {of: editor, direction: right}}}`)
  if you want something to its left or above it. The agent pane is always the
  one stored as `herdr_pane_id`. It gets the full session env, and it is
  created without best-effort handling: if it fails, the run fails.
  - Detail: when the agent is the first tab's root, it is `workspace.create`'s
    root pane with the session env, which is today's verified path. When it is
    a split, its env comes from `pane.split {env}` instead. That is in herdr's
    schema, but it carries the capability token, so verify it live before
    relying on it (§1). If it doesn't hold, fall back to requiring the agent
    to be the first tab's root.
- `name`: required on every other pane, unique across the whole layout,
  `[a-z0-9_-]{1,32}`. `agent` is reserved. It becomes the herdr pane label
  (`pane.rename`). Tab `name` is optional and becomes the tab label.
- `command`: optional. With no command the pane is a plain shell. The command
  is **shell text typed into the pane** with `pane.send_input`, the mechanism
  already verified for nvim. It is not a `layout.apply` argv. That gives the
  operator's PATH, rc files, `&&` and `$VAR`, and when the command dies the
  pane falls back to a shell with the error on screen, where the operator can
  press ↑ Enter.
- `split.of` must name an **earlier pane in the same tab** (or `agent`, in the
  first tab). `direction` is `right` or `down`, default `right`. `ratio` is
  0.1–0.9 and gives the share `of` keeps. It is optional and herdr's default
  applies when it is left out.
- `focus`: at most one per tab. It sets that tab's active pane; the default is
  the tab's root, or the agent in the first tab. The first tab is always the
  workspace's active tab, and the workspace is always created unfocused, so a
  run never takes over the operator's screen.
- `command` at most 1 KB.

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
  into one pane is logged and that pane is skipped, along with the panes split
  from it. A failed `tab.create` skips its whole tab. The rest continue, and
  none of this fails the run. A failure creating the agent pane (or the tab
  root it is split from) still fails the run and closes the workspace (the
  existing `rescue`).
- **Ordering**: the whole layout, every tab and split, is built before
  `start_agent!`, where the editor split is today. That keeps the
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
tabs:
  - panes:
      - agent
      - name: editor
        command: nvim .
        split: { of: agent, direction: right }
```

It keeps one special case: the built-in default skips the editor pane when
`nvim` is not on PATH, as `open_editor_pane` does today. An operator-written
layout gets no PATH check. A missing command shows up as `command not found`
in its own pane, which is visible and harmless. `tabs: [{panes: [agent]}]`
means "agent pane only".

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
- **new** `app/services/orchestrator/session_layout.rb`: `open!(run:, layout:,
  vars:, agent_env:, pane_env:)` builds the whole workspace and returns the
  agent pane (`workspace_id`, `tab_id`, `pane_id`) for `RunSessionRunner` to
  record. It walks tabs, then panes, in order: `workspace_create`/`tab_create`
  for a tab's root, `pane_split` for the rest, then `pane_rename` and
  `pane_send_input`. It is strict for the agent pane and anything the agent
  depends on (its tab root when the agent is a split), and best effort for
  everything else. It replaces `RunSessionRunner.open_editor_pane` and the
  inline `workspace_create` in `start!`.
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
  - `nil` → default equals today's editor split; `tabs: [{panes: [agent]}]` →
    no extra panes; many tabs with deep split trees parse and keep their order
  - rejects: `agent` missing, repeated or outside the first tab; a tab root
    with `split`, or a later pane without one; duplicate/reserved names; `of`
    naming a later pane, an unknown pane, or a pane in another tab; two
    `focus` in one tab; unknown `{{var}}`, bad
    ratio, more than the sanity cap, invalid YAML
  - interpolation shell-escapes values (a worktree path with a space and a `'`)
- `spec/services/orchestrator/session_layout_spec.rb`
  - issues `pane_split`/`tab_create`/`pane_rename`/`pane_send_input` in order
    with the right targets. A split `of: server` targets the pane id returned
    for `server`.
  - env passed to extra panes has `PORT`/`WORKFLOW_*` and **no**
    `WORKFLOW_RUN_TOKEN` or `GH_TOKEN`
  - a `Herdr::Error` on one pane logs, skips it and its dependants (panes whose
    `of` chain leads back to it; a whole tab if its root fails), and continues
    with the rest
  - agent as the first tab's root: env goes on `workspace_create`. Agent as a
    split: `workspace_create` gets the pane env and the agent's `pane_split`
    gets the session env. Either way the returned pane is the agent's.
  - a layout with several tabs, each with several splits, issues one
    `tab_create` per extra tab and one `pane_split` per non-root pane, all
    targeting the right ids
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

## Decided

- A workspace's layout may have any number of tabs, each with any number of
  splits. The agent pane is the only obligatory pane (operator, 2026-09-27).

## Open questions for the operator

1. Repo file: agree to leave it out of v1? If it's wanted later, is
   "explicit opt-in, read from `main` only" the right shape?
2. Should a layout be able to make a non-agent tab active when you first
   switch to the run's workspace? (v1: no, the agent's first tab is always
   active.)
3. One port per run enough, or named ports (`web`, `vite`) from the start?
4. Should the editor pane also get `GH_TOKEN` so `git push` from nvim/shell
   works like the agent's? (Proposed: no, least privilege. Today it has
   neither.)
5. Port range `3100..3999`: any local services that collide on this machine?

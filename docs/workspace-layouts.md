# Per-workspace layouts (design record)

> This is a design record, kept for its reasoning (see [the docs index](./README.md#design-records)).
> For how to use layouts, see [operating.md](./operating.md#workspace-layouts). Some class names
> below have since moved behind `Orchestrator::Runner` (the pane building is
> `Runner::SessionLayout`). Superseded in part: panes no longer get any environment from
> Paneyard (session env, and `Runner::ProcessEnv` with it, was removed), and the layout is
> built in the workspace herdr opens for the run's worktree (`worktree.create`), whose root
> pane is the agent's. Everything below about every pane getting the agent's env is history.

Status: implemented. This started as a proposal and has been updated to match
what was built, and what was verified live against herdr during
implementation (§1).

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
| Split a pane | `pane.split {target_pane_id, direction: right\|down, ratio?, cwd?, env?, focus?}` -> `{pane}` | Used for every pane after a tab's root, now with `ratio` and `env`. |
| New tab in a workspace | `tab.create {workspace_id, label?, cwd?, env?, focus?}` | Used for every tab after the first. Starts with one shell pane. |
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
pane only. This run's agent pane has `PANEYARD_RUN_ID`, `PANEYARD_RUN_TOKEN`
and `GH_TOKEN`. Its `nvim .` split (`ps eww` on the nvim pid) has only the
herdr-injected `HERDR_*` values. Every pane therefore gets exactly the env we
pass on the call that creates it, and nothing else. Since every pane is to get
the full session env (§3), each creating call must pass it explicitly.

**Verified live during implementation.** The operator approved these mutating
checks. They ran in a throwaway, unfocused `layout-probe` workspace running
only `sleep`/`env`, which was closed afterwards.

- **Env on a split or a new tab works.** `pane.split {env}` and
  `tab.create {env}` each set exactly their own pane's env. `env` run in each
  pane showed its own `PROBE_*` var and none of the others'.
- **`workspace.close` kills processes in every tab.** Both `sleep` pids in a
  second tab were gone after the close.
- **`tab.create {focus: false}` leaves things alone.** The workspace stayed
  unfocused and its active tab stayed the first one. An unfocused split
  leaves its tab's active pane on the tab's root.
- **`focus: true` on `pane.split` takes over the operator's screen.** It
  focused the whole herdr workspace and switched to that tab. The operator's
  focus was put back straight away. This is why the implemented schema has no
  per-pane `focus` (§3). Every tab's active pane is its first pane, and the
  agent is the first tab's first pane.
- **`ratio` is the share the split (target) pane keeps.** With 0.3 the
  target kept 23 of 78 columns.
- `pane.rename` sets a label that `layout.export` reports back. The first
  tab's label is `"1"` unless renamed (`tab.rename`).

Still unverified, and not needed by this design: what `layout.apply`'s `command`
argv does when it exits, and whether a process that ignores SIGHUP or
daemonises survives `workspace.close`. `tail -f` and foreman-style `bin/dev`
die with their pty; a double-forking server would not. That is the project's
own concern.

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

**Decided (operator, 2026-09-27): no repo file.** The layout lives only in
the workspace's settings in Rails. If a repo file is ever wanted, the shape to
use is an **explicit, per-workspace opt-in**, never auto-discovery, reading from
the **source checkout (`main`)** rather than the run's worktree, so a run cannot
change its own layout.

## 3. Schema

Stored as YAML text, and edited through the visual layout editor on the workspace form. Parsed and validated
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
  - name: logs
    panes:
      - name: dev-log
        command: tail -f log/development.log
      - name: test-log
        command: tail -f log/test.log
        split: { of: dev-log, direction: down }
      - name: sidekiq-log
        command: tail -f log/sidekiq.log
        split: { of: test-log, direction: right }
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
tab "logs":   [ dev-log                          ]
              [ -------------------------------- ]
              [ test-log           | sidekiq-log ]
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
- **`agent`**: a reserved bare entry. It must be the **first pane of the first
  tab**, and appear nowhere else. That makes it `workspace.create`'s root pane,
  and the active pane of the tab a run always opens on. (An earlier draft let
  the agent be a split, so something could sit to its left. That would have
  needed `focus: true` to keep the agent active, and that flag takes over the
  operator's screen; see §1.) The agent pane is always the one stored as
  `herdr_pane_id`, and it is created without best-effort handling: if it
  fails, the run fails.
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
- **No `focus`.** Each tab's active pane is its first pane. The first (agent)
  tab is always the workspace's active tab, and the workspace is always
  created unfocused, so a run never takes over the operator's screen
  (operator decision: always land on the agent tab).
- `command` at most 1 KB. Unknown keys are rejected rather than ignored.

**Env: every pane gets all of it (operator decision).** Every pane, including
the editor, log tails and plain shells, gets the same env hash the agent gets:
`SessionEnv.for_session(run:, capability_token:, extra:)`. That is the
workspace's recorded env vars, the sanitised process env, `PANEYARD_RUN_ID`,
the run's MCP capability token, `GH_TOKEN` with the git credential helper,
and the driver's extras. So `git push` from the nvim pane or a spare shell
works exactly as it does for the agent, and a command in any pane can
reference `$PANEYARD_RUN_ID` and the rest. `SessionLayout` passes that one hash
to every `workspace.create`, `tab.create` and `pane.split` it makes. This is a
change from today, where the nvim split has none of it (§1). The token dies
with the session anyway: `RunSession.authenticate_capability` only accepts
live sessions.

**No interpolation and no ports (operator decision).** There are no
`{{…}}` placeholders and no port allocation. Each pane's cwd is the worktree,
and the env above covers anything run-specific, so a command is plain shell
text. If two concurrent runs start servers on the same port, that is the
project's own command to adjust (for example `bin/dev -p $SOME_VAR` with a
workspace env var), not something the orchestrator allocates.

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
  its port and cwd'd inside a worktree that `WorktreeJanitor.release!` is about
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
  none of this fails the run. A failure creating the agent pane
  (`workspace.create` itself) still fails the run.
- **Invalid stored layout**: a layout is validated on save. If one stored
  earlier no longer validates at session start, the run falls back to the
  default layout with a log warning, rather than failing to start.
- **Ordering**: the whole layout, every tab and split, is built before
  `start_agent!`, where the editor split is today. That keeps the
  operator's first view complete, and their shells start up while the agent's
  shell is settling. Opening them after the agent pane has settled
  (`wait_for_available_shell!`) would slow start-up for no gain.
- **Resume** (`start!(resume_session_id:)`): a resumed session opens a new
  workspace, so it gets the layout fresh, with the new session's env.

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

1. Migration: `add_column :workspaces, :layout, :text`. No backfill.
2. `WorkspaceLayout` (parse, validate, default) and the new herdr
   client calls, with specs. Move `open_editor_pane` behind the layout, which
   produces the default. The editor pane then gets its `editor` label and the
   full session env, and is otherwise unchanged.
3. `mark_pane_lost!` closes the workspace. Worth doing even before layouts
   land, because it is correct today too.
4. Workspace edit form: a `layout` textarea (prefilled with the default as a
   comment/example), with validation errors shown inline.

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
- **MCP boundary**: `update_workspace_layout` is admin-only. A run session
  cannot change the layout; if it wants another process it can start one itself.
- **Workspace-first**: the config is a `Workspace` attribute, edited from the
  repository's `paneyard.layout` Herdr action.

## Alternatives rejected

| Alternative | Why not |
|---|---|
| Repo file `.orchestrator/layout.yml` (alone, or with precedence) | See §2: read from `main` anyway, rewritable by runs with no review, pollutes unrelated repos, mostly operator preference. Possible later as an explicit opt-in read from `main`. |
| `layout.apply` for the whole thing | It creates a *new* tab, and with `tab_id` it replaces the tab and kills its PTYs. The agent pane comes from `workspace.create` and must survive, so the agent's tab can't be built this way. Its `command` argv exit semantics are also unverified, and it bypasses the operator's shell, which `bin/dev`-style commands need for PATH/rbenv. It could build *non-agent* tabs in one call later, once verified live. |
| Rails supervising extra panes (restart on crash, health checks, wait-for-ready before prompting the agent) | That is orchestration. A crashed server is visible in its pane, and the agent or operator restarts it. |
| Tracking extra pane ids on `RunSession` | Nothing needs them: `workspace.close` covers teardown, and reconcile must *not* look at them. |
| Giving extra panes a reduced env (no token, no `GH_TOKEN`) | Operator decision: every pane gets every env var, so a spare shell or nvim can push and talk to the run exactly like the agent. |
| `{{…}}` interpolation and per-run port allocation | Operator decision: panes don't need allocated ports, and env vars already cover run-specific values. |
| Auto-detecting from `Procfile.dev`/`bin/dev` | Too magic, and one `bin/dev` pane (foreman multiplexes) already covers it explicitly. |
| Raw YAML textarea as the only editor | Replaced by the visual editor at the operator's request. Storage stays YAML text: JSON is valid YAML, and the editor's JSON is stored as canonical YAML. |

## What changed

- `db/migrate/20260927090000_add_layout_to_workspaces.rb`, `db/schema.rb`:
  `workspaces.layout` (text, nullable).
- `app/models/workspace.rb`: validates the layout (`WorkspaceLayout.errors_for`),
  and normalises CRLF/blank input, with blank stored as `NULL` (the default).
- **new** `app/services/orchestrator/workspace_layout.rb`: `parse` and
  validate into `Tab`/`Pane` data objects. Also `DEFAULT_YAML`, and
  `for(workspace)`: the workspace's layout, else the default, which drops
  the editor pane when nvim is missing; an invalid stored layout also falls
  back to the default.
- **new** `app/services/orchestrator/session_layout.rb`: `open!(label:, cwd:,
  env:, tabs:)` builds the workspace and returns the agent (root) pane.
  - Uses `workspace_create`, then `tab_rename` for a named first tab, then
    `pane_split` for each pane after a tab's root, then `tab_create` for each
    further tab. It labels each pane and types its command.
  - Everything goes in list order, with the same env on every call and
    `focus: false` throughout.
  - Best effort for everything but the agent.
- `app/services/orchestrator/herdr.rb`: `pane_split(ratio:, env:)`,
  `tab_create`, `tab_rename`, `pane_rename`, and the live findings above in
  the header comment.
- `app/services/orchestrator/run_session_runner.rb`:
  - `start!` builds through `SessionLayout`; the `open_editor_pane` and
    `EDITOR_*` constants moved into the layout default.
  - `mark_pane_lost!` now closes the whole workspace.
- `lib/paneyard_plugin/cli.rb`: a Herdr-native visual layout builder, with
  validation errors returned by the admin MCP tool.
  - The popup redraws a tree of tabs and panes after every operation; panes
    carry their command, split parent, direction, and optional ratio.
  - Tabs after the first and unreferenced leaf panes can be removed.
  - The agent row is fixed.
  - Saving sends YAML to `update_workspace_layout`; `Workspace` normalises a
    valid layout to canonical YAML and rejects invalid input unchanged.
  - **Reset to default** stores a blank layout again.
- `README.md` ("Workspace layouts"), `AGENTS.md`, `CLAUDE.md`.

## Spec coverage

All with `Orchestrator::Herdr` stubbed. No live socket.

- `spec/services/orchestrator/workspace_layout_spec.rb`
  - parsing a multi-tab, multi-split layout, commands kept verbatim
  - agent-only layouts
  - each validation error
  - the pane cap
  - `.for`: default, no nvim, own layout, and falling back when invalid
- `spec/services/orchestrator/session_layout_spec.rb`
  - the order and targets of every herdr call
  - the full env and `focus: false` on every call
  - plain-shell panes
  - skipping a failed pane with its dependants, and a failed tab
  - a failed label keeps the pane
  - a failed `workspace_create` raises
- `spec/services/orchestrator/run_session_runner_spec.rb`
  - the default nvim split now carries the session env
  - a workspace's own tabs and splits
  - a failed layout tab doesn't fail the launch
  - `mark_pane_lost!` closes the workspace
- `spec/jobs/run_session_reconcile_job_spec.rb`
  - only the agent pane is consulted
  - when only the agent pane is gone, the workspace is closed before the
    worktree is released
- `spec/services/orchestrator/herdr_spec.rb`: the new client calls.
- `spec/models/workspace_spec.rb`, `spec/system/workspaces_spec.rb`:
  validation, blank → default, and the edit form round-trip with its error
  display.

## Decided (operator, 2026-09-27)

- A workspace's layout may have any number of tabs, each with any number of
  splits. The agent pane is the only obligatory pane. The layout is saved in
  the workspace's (project's) settings.
- Default: one tab with the agent and nvim beside it. A project might instead
  have, say, the agent in tab 1 and a `logs` tab tailing its dev logs.
- No repo layout file.
- No port allocation and no `{{…}}` interpolation.
- Every pane gets all the session's env vars.
- A run always lands on the agent's tab.

No open questions.

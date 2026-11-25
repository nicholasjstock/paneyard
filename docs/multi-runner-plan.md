# Multi-runner: one orchestrator, a runner on each machine

Status: phase 1 of 4 implemented on the `multi-runner` branch (the runner registry, and a runner per run,
still local only). Phases 2 to 4 are planned. The four phases land on `multi-runner` and go into `main` as a
single pull request. Where a build changes the plan, the plan is updated to match.

## Goal

The operator can start work on either of two machines (the always-on Linux box and the laptop they sit at),
and can move a run from one to the other while it is in progress: its branch, its uncommitted changes and
its conversation go with it.

Today a second machine can only *drive* a Paneyard elsewhere (`PANEYARD_REMOTE_URL`,
`PaneyardPlugin::Remote`): every job still runs on the server's herdr, against the server's checkouts. This
plan lets jobs run on the second machine as well, under the same queue.

## Topology

- **One orchestrator.** One database, one queue, one set of MCP endpoints, on the always-on Linux box. It
  owns everything it owns today (see AGENTS.md, "Orchestrator and runner"): run and session state,
  concurrency, base branches, prompts, layouts, the janitor's decisions. There is no second database, no
  replication, and no leader election. Moving the orchestrator itself is out of scope.
- **A runner on each machine.** A runner is the half of the app that has to be on the machine with herdr,
  the agent CLIs, the checkouts and the worktrees (`Orchestrator::Runner`). The server's runner stays what it
  is today: `Runner::Local`, in the orchestrator's own process. The second machine runs a runner-only process
  (phase 2), which the orchestrator calls over HTTP through a `Runner::Remote` with the same public methods
  as `Runner::Local`.
- **Sessions report straight to the orchestrator.** A session on the second machine is launched with the
  server's tailnet `/mcp/run` URL in its MCP config, so `report_idle` and `job_finished` go to the
  orchestrator directly and never through its runner.

```
 laptop                                 always-on Linux box
 ┌──────────────────────────┐          ┌──────────────────────────────────────┐
 │ herdr + plugin (remote)  │          │ herdr + plugin                       │
 │ runner-only process  ◄───┼── HTTP ──┼─ orchestrator: DB, queue, /mcp/*     │
 │ checkouts, worktrees     │          │   Runner::Remote ──┘   Runner::Local │
 │ agent sessions ──────────┼── /mcp/run ──►                  (in-process)   │
 └──────────────────────────┘          └──────────────────────────────────────┘
```

## No auth on the tailnet

Runners are not authenticated, and neither is the orchestrator's interface to them. This is the trust model
the app already has: `/mcp/admin` carries no auth and is reachable from the second machine over the tailnet
today (`tailscale serve` in front of the loopback port; README, "second machine"). A runner's interface is no
more powerful than `/mcp/admin` already is (both, between them, hand an agent full access to a repository),
so adding a token to one and not the other would protect nothing. The same rules carry over:

- every process binds loopback only, and is exposed to the tailnet with `tailscale serve`, never Funnel;
- `config.hosts` and the MCP transports' DNS rebinding protection stay on, with the tailnet name added
  through `PANEYARD_ALLOWED_HOSTS`, for the runner-only process as for the orchestrator;
- the runner interface carries only plain data, as it does in process: no SQL, no Active Record, no
  arbitrary command execution. A remote runner exposes exactly `Runner::Local`'s public methods and
  nothing more.

If auth arrives later, it arrives for `/mcp/admin` and the runner interface together.

## Data model

- **`runners`** (`RegisteredRunner`, so that it does not shadow `Orchestrator::Runner` inside the
  `Orchestrator` module): `name` (unique), `kind` (`local` or `remote`), `url` (nil for local, required for
  remote), `max_concurrent_runs` (nullable: only the global cap applies), timestamps. There is exactly one
  `local` row (a partial unique index), and it can never be removed. It is made by the migration for an
  existing database, and by `RegisteredRunner.local` the first time anything asks for it otherwise, so a
  schema-loaded database (tests, `bin/sandbox`, `bin/preflight`) needs no seed.
- **`runs.runner_id`**, not null: the machine the run happens on. Existing runs were backfilled to the local
  runner; a new run defaults to it (`Run#default_runner`). Phase 4 changes it when a run moves.
- **`workspace_checkouts`** (`workspace_id`, `runner_id`, `repository_path`), unique per
  (workspace, runner) and per (runner, path): where the workspace's repository is checked out on each
  machine, because the same project lives at different paths on each. Backfilled from
  `workspaces.repository_path` for the local runner. `workspaces.repository_path` stays as the local
  checkout for now, and `Workspace` keeps the local row in step with it, so nothing that reads it breaks.
  Paths resolve through `Workspace#repository_path_for(runner)` and `Run#repository_path`, never by reading
  either column directly in run-scoped code.

`Orchestrator::Runner.for` resolves a runner object: a run or session gives its run's runner, a
`RegisteredRunner` gives itself, and a workspace or nil gives the local runner (the lobby, workspace
registration and settings checks, which have no run). A `local` record is `Runner::Local`. A `remote` record
raises `Runner::Error` ("remote runners are not implemented yet") until phase 2, which plugs in there and
nowhere else.

## Phases

### 1. A runner registry and a runner per run, still local only (done)

The tables above, their backfills, `Runner.for(run)` throughout the orchestrator, and per-runner repository
path resolution (the janitor sweeps each runner's runs in that runner's checkout). Nothing about how a run
behaves changes, and nothing can create a remote runner yet. No new `queue_run` arguments, no remote
client, no concurrency or plugin changes.

### 2. A runner-only process and `Runner::Remote`

- A runner-only mode of the app on the second machine: no queue, no recurring jobs, no MCP endpoints, its
  own small state directory, serving `Runner::Local`'s public methods over loopback HTTP as JSON (plain
  data in, plain data out, `Runner::Error`/`Unreachable`/`LaunchError` mapped onto the response).
- The plugin, in remote mode (`PANEYARD_REMOTE_URL` set), starts this process instead of no process at all,
  and registers it with the orchestrator over `/mcp/admin` (a new admin tool: name, url), idempotently on
  every start. It records where this machine's checkouts are as `workspace_checkouts` rows for that runner
  (from `PANEYARD_REMOTE_PATHS`, or registration from a pane there).
- `Runner::Remote` (in `app/services/orchestrator/runner/`, inside the boundary) is the HTTP client;
  `Runner.for` returns one for a `remote` record. A runner that does not answer raises
  `Runner::Unreachable`, so reconcile treats it as a blip, never as a dead session.
- A remote session's spec carries the orchestrator's tailnet `/mcp/run` URL (`PANEYARD_RAILS_URL`).
- The sandbox gains a fake remote runner (a second runner-only process against its own fake herdr), and
  `Orchestrator::Sandbox` refuses any runner url that is not its own.

### 3. Choosing a runner

- `queue_run` takes `runner:` (a runner name; default local), validated against the registry and the
  workspace's checkouts there.
- Per-runner caps: `RunConcurrency` counts slots per runner as well as globally, with
  `max_concurrent_runs` (nil means only the global cap), and `RunDispatchJob` skips a run whose runner is
  full without blocking runs for other runners.
- Plugin: the queue popup offers the runners (defaulting to the machine the pane is on); run lists show
  each run's runner. `get_run`/`list_runs` report it.
- The janitor, reconcile and model discovery work per runner; a runner that is unreachable is skipped for
  that sweep and its runs are left alone.

### 4. `move_run`

An admin tool (and plugin action) that moves a run from runner A to runner B:

1. **Close on A.** The ordinary Close session path (`SessionClose`), so the CLI is gone and nothing writes to
   the worktree. Transcripts are saved as they are today (`save_transcripts`).
2. **Export from A.** A's runner produces, as data the orchestrator relays:
   - the branch's commits since its base as a **git bundle**;
   - the **uncommitted state**: a binary diff of tracked changes (staged and unstaged) against HEAD, and a
     **tarball of untracked files** (respecting `.gitignore`);
   - the session's saved **transcripts**.
3. **Import on B.** B's runner fetches the bundle into its checkout, creates the run's worktree on the
   branch (`provision_worktree`, as a reopen would), applies the diff and unpacks the untracked tarball,
   and puts the transcripts where B's CLI looks for them.
4. **Reopen on B.** `runs.runner_id` becomes B and the run is reopened (`SessionReopen`). The CLI resumes
   the conversation when it can; when it cannot (a different path or CLI install), the existing fresh-start
   fallback (`RunPrompt.compose_reopened`, the task plus the newest checkpoint) covers it.
5. **A's worktree** is then an ordinary closed run's worktree there, kept until its work is safe, which the
   janitor checks as it does today. Nothing is force-removed.

Paneyard still never commits or pushes: the bundle carries commits the session already made, and the
uncommitted state crosses as a diff and a tarball, never as a commit. The transfer goes through the
orchestrator (runner A to orchestrator to runner B) so runners never need to reach each other.

## The single-machine guarantee

A single-machine install stays zero-config and behaves exactly as today, through every phase:

- the local runner is implicit and in-process: no daemon, no HTTP, no port, no registration step;
- its row exists without seeding (the migration, or `RegisteredRunner.local` on first use);
- with no remote runner registered, every run is local, `queue_run` needs no new argument, and nothing in
  the plugin changes;
- `bin/sandbox` and `bin/preflight` keep working on a fresh, schema-loaded database.

## Verification

- Phase 1: specs for the migrations' backfill and rollback (`spec/db/runner_registry_migration_spec.rb`),
  the default-local behaviour (`RegisteredRunner`, `Run`, `Workspace`), and `Runner.for` resolution,
  including the remote refusal; the boundary spec unchanged; `bin/verify --prod-copy` migrating a copy of
  the production database.
- Phases 2 to 4 add a fake remote runner to the lifecycle spec and `bin/sandbox verify`, so a run can be
  queued on, reported from, and moved between two runners without a second real machine.

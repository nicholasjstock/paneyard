# Multi-runner: one orchestrator, a runner on each machine

Status: all four phases implemented on the `multi-runner` branch (the runner registry and a runner per run; a
runner-only process and `Runner::Remote`; choosing a runner and per-runner caps; moving a run between runners).
Resuming a conversation on another machine after a move still needs live verification by the operator.
The four phases land on `multi-runner` and go into `main` as a
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
  remote), `orchestrator_url` (remote only: where that machine's sessions reach the orchestrator's `/mcp`,
  given when it registers), `projects_dir` (where it clones a workspace it has no checkout of; see "Checkouts
  on demand"), `max_concurrent_runs` (nullable: only the global cap applies), timestamps. There is exactly one
  `local` row (a partial unique index), and it can never be removed. It is made by the migration for an
  existing database, and by `RegisteredRunner.local` the first time anything asks for it otherwise, so a
  schema-loaded database (tests, `bin/sandbox`, `bin/preflight`) needs no seed.
- **`runs.runner_id`**, not null: the machine the run happens on. Existing runs were backfilled to the local
  runner; a new run defaults to it (`Run#default_runner`). Phase 4 changes it when a run moves.
- **`workspace_checkouts`** (`workspace_id`, `runner_id`, `repository_path`), unique per
  (workspace, runner) and per (runner, path): where the workspace's repository is checked out on each
  machine, because the same project lives at different paths on each. Backfilled from
  `workspaces.repository_path` for the local runner, a column that has since gone
  (`20261127100000_make_workspaces_a_name_and_an_origin`): a workspace is a name, an origin
  (`workspaces.origin_url`) and a default branch, and every runner, the local one included, has an optional
  checkout row. Paths resolve through `Workspace#repository_path_for(runner)` and `Run#repository_path`;
  `Workspace#repository_path` is only the local runner's checkout, or nil.

`Orchestrator::Runner.for` resolves a runner object: a run or session gives its run's runner, a
`RegisteredRunner` gives itself, and a workspace or nil gives the local runner (the lobby and settings
checks, which have no run; workspace registration names its runner, local by default). A `local` record is `Runner::Local`. A `remote` record
is a `Runner::Remote` for its url (phase 2), which plugs in there and nowhere else.

## Phases

### 1. A runner registry and a runner per run, still local only (done)

The tables above, their backfills, `Runner.for(run)` throughout the orchestrator, and per-runner repository
path resolution (the janitor sweeps each runner's runs in that runner's checkout). Nothing about how a run
behaves changes, and nothing can create a remote runner yet. No new `queue_run` arguments, no remote
client, no concurrency or plugin changes.

### 2. A runner-only process and `Runner::Remote` (done)

- `bin/runner` (`PANEYARD_ROLE=runner`): Puma alone on loopback (default port 3100), no Solid Queue, no
  recurring jobs, no `db:prepare`, no MCP endpoints, its own state directory (`PANEYARD_STORAGE_DIR`,
  `PANEYARD_RUNTIME_DIR`). Its only routes are `/up` (`X-Paneyard-Role: runner`) and
  `Runner::Endpoint` at `/runner`: `POST /runner/call` with `{ method, args, kwargs }` for one of
  `Runner::Wire::METHODS` (exactly `Runner::Local`'s public methods, plus `ping`), answered as
  `{ ok, result }` or `{ ok: false, error: { class, message, lost_prompts? } }`. Binary strings cross as
  `{ "$base64" }`. It takes only `application/json` and refuses an `Origin`, so no browser page can reach it.
- `Runner::Remote` is the HTTP client; `Runner.for` returns one for a `remote` record. Connection failures,
  timeouts and anything that is not the runner's own answer (a proxy's 502) are `Runner::Unreachable`;
  `RunSessionReconcileJob` then skips that runner's sessions for the sweep and reconciles the others.
- `register_runner` (admin-only, `Orchestrator::RunnerRegistration`): name, url, `orchestratorUrl`,
  `projectsDir` (since "Checkouts on demand") and checkouts (`[{ workspace, path }]`, each checked there with `check_repository` and recorded as that
  runner's `workspace_checkouts` row). Nothing is saved unless the runner answers `ping`; registering again
  updates it.
- A remote session's spec carries `runners.orchestrator_url` + `/mcp` (`RunSessionRunner.mcp_url(runner)`);
  local sessions and lobbies keep `PANEYARD_RAILS_URL`.
- The plugin, in remote mode with `PANEYARD_RUNNER_URL` (the runner's tailnet URL) set, runs `bin/runner`
  as a second daemon (`PaneyardPlugin::Daemon` with `role: "runner"`, `Paths#runner`'s files,
  `PANEYARD_RUNNER_PORT`, `PANEYARD_RUNNER_NAME` defaulting to the hostname) and registers it on every start
  of that process, or when what it would register changes, with each workspace that has a checkout here
  (its repository path through `PANEYARD_REMOTE_PATHS`, which keeps translating everything else). Without
  `PANEYARD_RUNNER_URL` nothing new starts. A repository from a pane there that the path prefixes do not map
  registers on that runner (`register_workspace`'s `runner`).
- `bin/sandbox start --remote-runner` and `bin/sandbox verify` run a second runner-only process with its
  own fake herdr and sandbox root, registered over `/mcp/admin`; `Orchestrator::Sandbox` refuses any runner
  url that is not a loopback one it started (`PANEYARD_SANDBOX_RUNNER_URLS`).

### 3. Choosing a runner (done)

- `queue_run` takes an optional `runner:` (a runner name). `Orchestrator::RunRunner` picks and checks it:
  the named runner, else the calling run's own runner (a session queuing follow-up work), else the
  workspace's runner when it is checked out on only one, else local. A named runner must exist and have a
  checkout of the workspace (since "Checkouts on demand": or a projects directory to clone one into); the
  error lists the ones that do. The run's `target_root` starts as that runner's checkout (or where the clone
  will go), and the base branch is checked there (`RunBaseBranch.problem(..., runner:)`) when there is one.
- Per-runner caps: `RunConcurrency` counts slots per runner as well as globally (`in_flight_by_runner`,
  `slots`), with `max_concurrent_runs` (nil means only the global cap). `RunDispatchJob` makes one
  oldest-first pass, passing over a run whose runner is full, so it never blocks runs for other runners.
  Dependencies (`after`) are unchanged.
- An admin-only `list_runners`: name, kind, url, cap, in-flight runs, the workspaces checked out there, and
  reachability (the local runner always; a remote one if `Runner.for` gives an object that answers `id`).
- `get_run`/`list_runs` report each run's `runner`; `list_workspaces` lists each workspace's `runners` (name,
  kind, path there); `queue_run` reports `runner`, and `runnerCapacity` when the runner has a cap.
- Plugin: the queue popup offers the workspace's runners only when there is more than one, defaulting to
  this machine's: the local runner, or in remote mode the runner named `PANEYARD_RUNNER_NAME`, else the one
  named after this host, else the only remote one. With one runner nothing changes.
- The janitor already sweeps per runner (phase 1) and never treats any runner's checkout as a run's
  worktree. Reconcile skips an unreachable runner's sessions for the sweep (phase 2). Still to do: model
  discovery per runner (`list_models` still asks the local one).

### 4. `move_run` (done)

An admin-only tool, `move_run(workspace, runId, toRunner, force)`, and the plugin run screen's `m` (**Move to
<runner>**; `get_run`'s `moveTo` lists the candidates), moving a run from runner A to runner B
(`Orchestrator::RunMove`):

1. **Check, then close on A.** B is another registered runner with a checkout of the workspace (or a projects
   directory: it clones one first, `WorkspaceCheckout.ensure!`), the run has a branch, it is not queued or starting, and a session still working is refused unless forced. B is asked
   which of the run's base commits it has (`known_commits`, fetching origin there if one is missing, read-only)
   *before* anything changes, so an unreachable B refuses with nothing touched. A live session then goes
   through the ordinary Close session path (`SessionClose`), which saves its transcripts.
2. **Export from A** (`export_run`, `Runner::RunTransfer` and `Runner::Transcripts`), as plain data the
   orchestrator relays:
   - the branch as a **git bundle**, leaving out the base commits B already has (the whole branch when it has
     none, e.g. a base branch that was never pushed);
   - the **uncommitted state**: binary diffs of the staged (`HEAD` to index) and unstaged (index to worktree)
     changes, a **tar of untracked files** (respecting `.gitignore`; pure Ruby, so it reads the same on Linux and
     macOS), and a **fingerprint**: HEAD, the index's tree and the whole worktree's tree (written with a
     scratch index), comparable by object id across machines;
   - the run's saved **transcripts**.
3. **Import on B** (`import_run`): the bundle is fetched into a local branch of the same name (created, or
   fast-forwarded; a diverging branch is refused), the worktree provisioned on it (`Worktrees.provision!`),
   the staged diff applied with `--index`, the unstaged one and the untracked files on top, and the result
   checked against the fingerprint. A failure undoes the import there (the worktree and branch it made are
   copies of work still on A). Then `restore_transcripts` puts the transcripts where B's CLI looks for the new
   worktree (claude's `projects/<encoded cwd>/`, codex's `sessions/YYYY/MM/DD/`), rewriting their recorded cwd.
4. **Reopen on B.** `runs.runner_id`, `target_root` and `source_root` become B's, the move is recorded
   (`run_moves`, `RunMoveRecord`: from, to, what crossed, the worktree left behind), and the run is reopened
   (`SessionReopen`). The CLI resumes the conversation when it can; when it cannot, the existing fresh-start
   fallback (`RunPrompt.compose_reopened`, the task plus the newest checkpoint, now with a note that the run
   moved) covers it. Resume across machines was confirmed live for claude (macOS and Linux, both ways);
   codex is untried.
5. **A's worktree** is released by the usual rule (`release_worktree`), usually kept, and stays in the
   janitor's view through its `run_moves` row (`WorktreeJanitor.sweep_left_behind`) until its work is saved.
   Nothing is force-removed. Moving the run back to A reuses that worktree, reset first, only while its
   fingerprint is still the one it left with (`import_run`'s `replaceable`); one changed since is refused.

Paneyard still never commits or pushes: the bundle carries commits the session already made, and the
uncommitted state crosses as diffs and a tarball, never as a commit. The transfer goes through the
orchestrator (runner A to orchestrator to runner B) so runners never need to reach each other. In a sandbox,
moving stays inside its root: repository paths are guarded, origin is fetched only when it is inside the root,
and transcripts are written into a CLI's config only when that is inside the root.

### Checkouts on demand (done)

A runner without a checkout of a workspace stops being a dead end, and the local runner stops being special:

- **The workspace model.** A workspace is a name plus an origin; `workspaces.repository_path` is gone, every
  existing workspace keeping its local checkout as a `workspace_checkouts` row. `list_workspaces` still says
  `repositoryPath` (the local checkout, or null), plus `originUrl` and `runners`: each runner a job could run on,
  with its checkout there or `checkedOut: false`.
- **`ensure_checkout(path:, origin_url:, default_base_branch:)`** on every runner (`Runner::Repositories`,
  `Wire::METHODS`, a slow method for `Runner::Remote`): a checkout already at `path` whose origin is the same
  repository (normalised, so `git@host:o/r` and `https://host/o/r.git` match) is reused as it is; nothing there,
  or an empty directory, gets a `git clone` with that machine's own credentials (no prompt, a timeout that kills
  the clone's process group, the default branch made local if origin's HEAD is another); anything else is
  refused untouched. A sandbox clones only into its root, from an origin inside it (`Sandbox.guard_clone!`).
- **A projects directory per runner**, `<projects dir>/<workspace name>` being where it clones: the plugin's
  setup asks for it (default `~/Source`) and writes `PANEYARD_PROJECTS_DIR` to its `.env`; a remote runner
  sends it with `register_runner` (`runners.projects_dir`); the local runner uses the env value, else the
  column (where the old `projects_dir` setting was migrated, and `update_settings projectsDir` saves), else
  `~/Source`. `create_workspace` puts new projects there too.
- **`Orchestrator::WorkspaceCheckout.ensure!(workspace, runner)`** returns the path on that runner, cloning
  and recording the checkout when it has none, with the origin stored on the workspace or read from another
  runner's checkout. It runs at a run's launch (`GitWorktree.provision!`; queuing stays fast, and a failed
  clone fails the launch with git's reason), before `move_run`'s `known_commits`, and when the lobby opens on
  a machine without a checkout. `queue_run`'s `runner` and `get_run`'s `moveTo` accept every runner with a
  checkout or a projects directory.
- **Registration on any runner.** `register_workspace` and `create_workspace` take an optional `runner`, check
  (or create) there, and record only that runner's checkout, so a repository that exists only on another
  machine registers with that machine's runner.

After merging, the orchestrator needs a restart (a migration), and so does each remote machine's `bin/runner`
(a new runner method).

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
- Phase 2: `spec/integration/remote_runner_lifecycle_spec.rb` (a real `bin/runner` subprocess with its own
  fake herdr: register, launch, report, reconcile while it is down, close, janitor), `Runner::Remote` and
  `Runner::Endpoint` specs over real HTTP, the sandbox's runner-url guard, and a remote-runner scenario in
  `bin/sandbox verify`.
- Phases 3 and 4 extend the same, so a run can be queued on and moved between two runners without a second
  real machine. Phase 4: `spec/services/orchestrator/runner/run_transfer_spec.rb` (real git: two clones and a
  bare origin; committed-only, staged and unstaged, untracked, binary and symlinked files, a base never
  pushed, a diverging destination branch, a failed fingerprint undoing itself, moving back), the transcripts'
  export and placement, `spec/services/orchestrator/run_move_spec.rb` (refusals, an unreachable destination,
  a failure after closing, the janitor and the worktree left behind), a move there and back in
  `spec/integration/remote_runner_lifecycle_spec.rb`, and a move in `bin/sandbox verify`.
- Checkouts on demand: `spec/services/orchestrator/runner/ensure_checkout_spec.rb` (real git: clone, reuse,
  every refusal, the sandbox), `spec/services/orchestrator/workspace_checkout_spec.rb`, the launch path
  (`git_worktree_spec.rb`), `queue_run` and `move_run` to a runner with no checkout, `register_workspace` on a
  remote runner, the migration's backfill (`spec/db/workspace_origin_migration_spec.rb`), a clone over the wire
  and a remote-only workspace in `spec/integration/remote_runner_lifecycle_spec.rb`, and a remote-only
  workspace cloned here in `bin/sandbox verify`.

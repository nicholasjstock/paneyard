# Session startup context: audit and proposed rework

Run `run-20260927-080502-c3fb`, audited against `main` at `5caebbb`. **No runtime behavior was changed.** This
document lists everything a new run session has in its context window when it starts, flags what is wrong with
it, and proposes replacement text.

Contents:

1. [How a session starts](#1-how-a-session-starts-the-code-path)
2. [Inventory](#2-inventory)
3. [Findings](#3-findings)
4. [Proposed rework](#4-proposed-rework)
5. [Decisions for the operator](#5-decisions-for-the-operator)
6. [Appendix: stale code comments](#appendix-stale-code-comments-not-context-but-found-on-the-way)

---

## 1. How a session starts (the code path)

`RunDispatchJob` → `StartRunSessionJob#perform` → `GitWorktree.provision!` (a `workflow/<name>` branch cut from the
**local** `main` HEAD, not `origin/main`) → `RunSessionRunner.start!`:

1. `RunSession.issue_capability` creates a bearer token for `/mcp/run`.
2. For claude only, `SessionArgs.write_claude_mcp_config` writes `tmp/run_sessions/<run>/mcp.json` (in the
   orchestrator's own checkout).
3. `SessionArgs.build` builds the command, its args and any extra env for the driver.
4. `SessionEnv.for_session` builds the pane environment.
5. `RunPrompt.compose` builds the prompt. `start!` accepts a `prompt:` override, but its only caller,
   `StartRunSessionJob`, never passes one. The prompt is written to `tmp/run_sessions/<run>/prompt.txt`.
6. `Herdr.workspace_create(cwd: worktree, env:)`, then an nvim pane is split beside it (`open_editor_pane`). The
   agent never sees or talks to that pane.
7. `Herdr.agent_start(kind:, args:)`. For codex, an Enter keypress then dismisses its trust gate.
8. After `wait_until_ready!`, `Herdr.agent_prompt(pane, text)` sends the prompt as the **first user message**,
   followed by an Enter if the text was not submitted.

After that, the only input Rails ever sends is `RunSessionRunner.prompt!`, which delivers the operator's
run-screen message box text as a plain user turn with no framing added.

Nothing reaches the model through a system prompt. `SessionArgs` passes no `--system-prompt`,
`--append-system-prompt`, codex `instructions`/`developer_instructions`, or opencode agent prompt. The `/mcp/run`
server declares no `instructions` either: `RunMcpServer.build` omits the argument, even though mcp 0.23.0 supports
it.

`start!(resume_session_id:)` is also never called with an id, so the resume branches of `SessionArgs` are dead
code today.

## 2. Inventory

Legend: **R** means Rails injects it and it applies to every workspace. **W** means the CLI loads it from the
worktree, so it depends on the target repo. **M** means it comes from the operator's machine-global CLI config
and applies to every run on this machine.

| # | Source | Kind | claude | codex | opencode | Where it's defined |
|---|---|---|---|---|---|---|
| 1 | Task wrapper (first user message) | R | ✓ | ✓ | ✓ | `app/services/orchestrator/run_prompt.rb` |
| 2 | CLI flags (model, permissions, MCP wiring) | R | ✓ | ✓ | ✓ | `app/services/orchestrator/session_args.rb` |
| 3 | System prompt / append-system-prompt | R | — | — | — | none exists |
| 4 | MCP server `workflow` at `/mcp/run`: name, title, instructions | R | ✓ | ✓ | ✓ | `run_mcp_server.rb` (no instructions) |
| 5 | MCP tool descriptions and schemas (9 tools) | R | ✓ | ✓ | ✓ | `app/services/mcp_tools/*.rb` |
| 6 | Pane environment variables | R | ✓ | ✓ | ✓ | `session_env.rb`, `session_args.rb`, `workspace_env_vars.rb` |
| 7 | `CLAUDE.md` in the worktree (and parent dirs) | W | ✓ auto | — | fallback only if there is no AGENTS.md | repo |
| 8 | `AGENTS.md` in the worktree | W | only if the agent reads it (CLAUDE.md tells it to) | ✓ auto | ✓ auto | repo |
| 9 | `.claude/`, `.codex/` in the worktree | W | skills dir (inert stub) | skills dir (inert stub) | — | repo |
| 10 | Other repo docs (README, ARCHITECTURE, PLAN, TODO…) | W | on demand | on demand | on demand | repo |
| 11 | Claude global settings, hooks, plugins, skills | M | ✓ | — | — | `$CLAUDE_CONFIG_DIR` (`~/.config/claude`) |
| 12 | Claude auto-memory for this repo | M | ✓ | — | — | `~/.config/claude/projects/<main-checkout>/memory/` |
| 13 | Codex global config, skills, rules, hooks | M | — | ✓ | — | `$CODEX_HOME` (`~/.config/codex`) |
| 14 | opencode global config | M | — | — | none on this machine | `~/.config/opencode` (absent) |
| 15 | herdr SessionStart hooks | M | ✓ (silent) | ✓ (silent) | — | `~/.config/{claude,codex}/…/herdr-agent-state.sh` |
| 16 | The CLI's own built-in system prompt | — | ✓ | ✓ | ✓ | vendor; out of our control |

### 2.1 Task wrapper (literal)

`RunPrompt.compose` joins three sections. `session_driver:` is accepted and **unused**, so every driver gets the
same text. Rendered, with placeholders in `{}`:

```text
# Runtime identity (authoritative)

- runId: {run.run_id}
- workspace: {run.workspace.name}
- worktree: {run.target_root}
- branch: {run.branch_name || "(not provisioned)"}

Rails authenticates your MCP calls with this session's private capability -- do not invent or
alter identity fields. The workflow tools are MCP tools registered under the `mcp__workflow__`
prefix (e.g. `mcp__workflow__report_idle`). If they are not directly callable they are deferred:
load them FIRST with ToolSearch using their full prefixed names (e.g. query
`select:mcp__workflow__report_idle`) -- bare, unprefixed names will not match. Never state or imply
that you called a tool you did not actually invoke; if a required tool cannot be loaded or
called, say exactly that instead of narrating a call that never happened.

# How this run works

You own this worktree end to end. It is a real git worktree on branch `{branch}`,
checked out at `{worktree}`, and nobody else is working in it -- you do not need to
coordinate, ask permission for ordinary changes, or scope your edits to a pre-approved file list.

An operator is watching this pane and can type into it. If you are genuinely blocked on a
decision only they can make, ask here and wait -- that is cheaper than guessing.

When the work is finished:

1. Commit your work and push the branch: `git push -u origin {branch}`.
2. Call `report_idle` with outcome `done`.

`report_idle` does not end the run. It tells the operator you have stopped working, and its
summary is the record of what you did: the run screen shows the reports in order and nothing
else, so the operator reads them instead of this pane. Write each summary as a full report in
Markdown, not a one-liner -- what you changed and why, how it was verified (commands run and their
results), what failed or was left out, what state the worktree and branch are in, and what you
think should happen next. The operator may send you more work; if so, do it and call
`report_idle` again when you next go idle. Each report covers only the interval since your
previous one and they are kept as the run's history, so do not restate earlier reports.

If you cannot finish, report anyway -- `blocked` if you need the operator, `failed` if the task
cannot be done as specified -- and say why. Do not end your turn without calling it: until you do,
Rails cannot tell you are idle rather than still working, and the run holds a concurrency slot.

# Task
{"\nFiles attached at launch (read them with `read_workflow_artifact`): a, b.\n" — only if launch_artifacts}
{run.task}
```

About 2.9 KB before the task. `McpTools::ReadRunPromptTool` also calls `compose`, but that tool belongs to the
dormant admin chat and is not mounted anywhere.

### 2.2 CLI flags (`SessionArgs.build`)

None of these add text to the model's context directly. They decide which model runs, what permissions it has
and which MCP server it gets.

| Driver | Command line | Context-relevant effect |
|---|---|---|
| claude | `claude --model {model\|opus} --permission-mode bypassPermissions --add-dir {worktree} --mcp-config tmp/run_sessions/<run>/mcp.json --strict-mcp-config` | `--strict-mcp-config` means the only MCP server is `workflow`, so any `.mcp.json` in the repo is ignored. There is no `--setting-sources` restriction, so user, project and local settings, CLAUDE.md, auto-memory, skills, plugins and hooks all load. |
| codex | `codex --model {model\|gpt-5.6-terra} -s danger-full-access -c mcp_servers.workflow.url="…/mcp/run" -c mcp_servers.workflow.bearer_token_env_var="WORKFLOW_RUN_TOKEN" -c mcp_servers.workflow.default_tools_approval_mode="approve" -C {worktree}` | This adds `workflow` alongside any MCP servers already in `$CODEX_HOME/config.toml` (none on this machine). The global `config.toml` otherwise applies in full, including `model_reasoning_effort = "low"` and `personality = "pragmatic"`. |
| opencode | `opencode -m {model} --auto --mini {worktree}` with `OPENCODE_CONFIG_CONTENT={"mcp":{"workflow":{"type":"remote","url":"…/mcp/run","headers":{"Authorization":"Bearer …"}}}}` | The inline config merges over the global and project opencode config. |

The claude `mcp.json` (literal shape):

```json
{ "mcpServers": { "workflow": { "type": "http", "url": "http://127.0.0.1:3000/mcp/run",
  "headers": { "Authorization": "Bearer <capability>" } } } }
```

### 2.3 MCP `/mcp/run` server

`MCP::Server.new(name: "workflow", title: "Workflow Run", version: "0.1.0", tools: TOOLS)`, with **no
`instructions`**. The tool descriptions below are verbatim, and each one is loaded into context in every session:

| Tool | Description (verbatim) | Params |
|---|---|---|
| `ping_tool` | "Health-check tool, proves the MCP transport is wired up." | none |
| `report_idle` | "Report that you have stopped working and say where the run stands. Call it every time you go idle: when you have finished the task (outcome `done`), need the operator and cannot continue (`blocked`), or have concluded the task cannot be done as specified (`failed`). Before reporting `done`, commit and push your branch. This does NOT end the run -- the operator reads your reports and decides what happens next, and may well send you more work; when you go idle after that, report again. Each report is a checkpoint covering only the interval since your previous one, and they are kept as the run's history, so do not restate earlier reports. Not calling it is the one real failure: until you do, Rails cannot tell you are idle rather than still working." | `runId`*, `outcome`* (done/blocked/failed), `summary`* ("A full Markdown report of this slice of work -- the operator reads these instead of the pane. What you changed and why, how you verified it (commands and results), what failed or was left out, the state of the worktree and branch, and what should happen next.") |
| `write_workflow_artifact` | "Write one managed workflow artifact into the workspace-declared artifact directory, scoped to the run." | `runId`*, `artifactName`*, `content`* |
| `read_workflow_artifact` | "Read a bounded window of one managed workflow artifact. Start with the default preview, then request a later offset only when more evidence is needed." | `runId`*, `artifactName`*, `inheritFromRunId`, `offset`, `limit` |
| `record_workspace_env_var` | "Persist an environment variable this workspace's commands need (e.g. a bundle install workaround) so every future worker and start_run_command in this workspace gets it automatically, instead of every future worker rediscovering the same workaround. Recording the same name again overwrites its value. value is set directly as a literal process environment variable -- it is never passed through a shell, so it must already be a fully resolved value (e.g. an absolute path like /tmp/bundler_gems), not shell syntax like $TMPDIR/bundler_gems or \`command\`, which would reach the next process as that exact unexpanded literal string. Do not use this for secrets you would not want visible in this workspace's stored configuration." | `runId`*, `name`*, `value`*, `evidenceRef`* (undescribed) |
| `queue_run` | "Queue a new run. This is the only way you can cause code to change -- you yourself cannot write to any repository. A queued run gets its own git worktree, its own branch, and its own session, and ends with that branch pushed for the operator to review (it does not open a pull request). It starts when a slot frees, not immediately. Write the task the way you would brief a capable colleague who cannot ask you a follow-up question: state the goal, the constraints, and how they will know it worked. Defaults to the calling run's own workspace, or the oldest registered workspace if called from outside a run; pass workspace to target a different one." | `task`*, `workspace`, `driver` |
| `list_runs` | "List a workspace's runs, newest first, with enough state to answer "what is happening right now" -- status, which agent, whether a session is live and what it is doing, branch, and pull request. Defaults to runs that are still in flight; …" | `workspace`, `includeFinished`, `limit` |
| `get_run` | "Everything known about one run: status, its session's live state, the worktree and branch it owns, any launch error, and its checkpoint reports. …" | `runId`*, `workspace` |
| `list_workspaces` | "List every registered workspace -- the names queue_run, list_runs, and get_run accept as workspace -- with its source checkout path and how many runs it has in flight. …" | none |

The tool names each CLI shows the model differ: claude uses `mcp__workflow__report_idle`, and codex and opencode
each use their own prefix convention.

### 2.4 Pane environment (`SessionEnv.for_session`, later keys win)

1. Workspace env vars recorded through `record_workspace_env_var`.
2. Keys set to nil, meaning "not set": `BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_LOCKFILE BUNDLE_APP_CONFIG
   BUNDLER_VERSION BUNDLER_SETUP RUBYOPT GEM_HOME GEM_PATH CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH
   CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION CLAUDE_PID CLAUDE_EFFORT AI_AGENT RAILS_ENV`. herdr drops nils,
   so these only act as a guard.
3. `CODEX_HOME` (resolved), and `OPENAI_API_KEY` from the environment or `auth.json`, or nil if the value is masked.
4. `WORKFLOW_RUN_ID`, and `WORKFLOW_RUN_TOKEN` (the bearer capability).
5. Git credentials, when a token is available: `GH_TOKEN` (a GitHub App installation token, or else
   `gh auth token`), `GIT_TERMINAL_PROMPT=0`, and `GIT_CONFIG_COUNT/KEY_0/VALUE_0` = `credential.helper=!gh auth
   git-credential`.
6. For opencode only: `OPENCODE_CONFIG_CONTENT`.

herdr adds `HERDR_ENV`, `HERDR_PANE_ID` and `HERDR_SOCKET_PATH`. The pane shell also runs the operator's rc files.
None of these reach the model as text unless it runs `env`, and nothing tells it that `WORKFLOW_RUN_ID` exists.

### 2.5 Files the CLI loads from the worktree (this workspace)

- **`CLAUDE.md`** (31 lines). Claude loads it at startup. It covers the operating context, "Rails schedules",
  report_idle, Close session, no PRs, herdr, worktrees, the MCP boundary and verification. It tells the agent to
  read `AGENTS.md` first, but as prose, not an `@AGENTS.md` import, so claude only sees AGENTS.md if it chooses
  to read it.
- **`AGENTS.md`** (95 lines). Codex and opencode load it at startup. Claude reads it only when it decides to. It
  covers the same model in more depth.
- There is no `CLAUDE.md` or `AGENTS.md` in any parent directory (`..`, `../..`, `~`).
- **`.claude/skills/infrastructure/agents/openai.yaml`** and **`.codex/skills/infrastructure/agents/openai.yaml`**
  each hold only `display_name: "Infrastructure Operations"` and `short_description: "Debug workers, services,
  queues, and streams"`. There is **no `SKILL.md`**, so neither CLI loads anything. Both are leftovers from
  `4889ec5` (the persona era).
- There is no `.claude/settings*.json`, `.claude/commands/`, `.mcp.json`, or `opencode.json` in the repo.
- On-demand root docs that a session may open: `ARCHITECTURE.md`, `PLAN.md`, `TODO.md`, `COST_ANALYSIS.md` and
  `TEST_COVERAGE_MATRIX.md` all describe the planner/worker/chaperone era. See F6.

For **other target repos**, rows 7–10 are whatever that repo ships. Rails cannot assume any of it exists, and a
claude session in an AGENTS.md-only repo never sees AGENTS.md unless told to read it.

### 2.6 Operator-global config (this machine)

- **Claude** (`~/.config/claude`):
  - `settings.json`: `model: opus` (overridden by `--model`), the plugin `ruby-lsp`, and a SessionStart hook
    running herdr's `herdr-agent-state.sh`. The hook reports state over the herdr socket and prints nothing, so it
    adds no context.
  - Synced skills: chrome-browser, built-in-browser, computer-use, docx, pdf, pptx, xlsx, docs, morning,
    deep-research, import-memory and skill-creator. Their names and descriptions appear in every claude
    session's skill list. All of it is noise for a run session.
  - `~/.claude/settings.json` (`acceptEdits`, allow-list) is a legacy location. With `CLAUDE_CONFIG_DIR` set it
    is not user settings, and `bypassPermissions` overrides it anyway.
- **Claude auto-memory**: claude resolves a worktree's memory to its main checkout, so every claude run in this
  workspace loads `~/.config/claude/projects/-Users-stockn-Source-workflow-orchestrator-main/memory/MEMORY.md`.
  This session's own context confirms it. The index currently holds one entry, pointing to
  `add-a-job-means-queue-run.md`. See F3.
- **Codex** (`~/.config/codex`):
  - `config.toml` sets `model = "gpt-5.6-sol"` (overridden), `personality = "pragmatic"` and
    `model_reasoning_effort = "low"` (**not** overridden), plus trust entries.
  - `hooks.json` runs the herdr SessionStart hook, which is silent.
  - `rules/default.rules` is a list of per-command allow rules, mostly from another project and irrelevant under
    `danger-full-access`.
  - `skills/bus-handoff/SKILL.md` has the description "Deprecated. Use planner-bus for planner handoffs to the
    shared bus." and a body about planners, the bus and worker requests. See F3.
  - `memories/` is empty.
- **opencode**: `~/.config/opencode` does not exist.

---

## 3. Findings

Severity is **H** (actively misleads a session or breaks something it is told to do), **M** (wrong or
contradictory but usually survivable), or **L** (noise or polish).

### Broken or actively misleading

**F1 (H): Launch attachments. The prompt tells the session to use a tool that always crashes, and the files are not
in the worktree.**
- `read_workflow_artifact` calls `run.artifact_source_run` and `run.available_launch_artifacts`. Neither method
  exists (`Run.method_defined?` returns false for both, and no spec covers the tool). Every call raises
  `NoMethodError`, which the tool does not rescue.
- `RunsController#create` copies uploads to `ArtifactStore.resolve_path(@run.target_root, …)` while
  `target_root` is still `workspace.source_root`. The files therefore land in
  `<main checkout>/.workflow-orchestrator/artifacts/<run>/`, an untracked directory in `main`. The worktree
  provisioned later never contains them, and once `target_root` points at the worktree even a fixed read would
  look in the wrong place.
- As a result, a session given attachments is told "read them with `read_workflow_artifact`" and cannot.

**F2 (H): The `queue_run` description tells a run session it cannot change code.** "This is the only way you can
cause code to change -- you yourself cannot write to any repository." That line was written for the admin chat.
The tool class is shared, so every run session, whose whole job is changing code, reads it. It is the one live
contradiction of "you own this worktree end to end", and it pushes sessions toward delegating their task.

**F3 (H, machine-global): Two operator-global sources inject stale or conflicting instructions.**
- The Claude auto-memory entry `add-a-job-means-queue-run` says: "queue it as an orchestrator run with
  `mcp__orchestrator__queue_run` instead of implementing it inline… Don't edit the main checkout for it." It
  loads into **every claude run session in this workspace**. The tool name is wrong in a run session (the server
  there is `workflow`), and "don't implement, queue a run" is the opposite of a run session's job. Combined with
  F2, a session has two signals telling it to delegate.
- Codex's global `bus-handoff` skill ("planner handoffs to the shared bus… worker-request entries") is the
  planner and question-protocol vocabulary the architecture forbids, and it is listed in every codex session.
- Codex's global `model_reasoning_effort = "low"` silently applies to every codex run, even though
  `SessionArgs.codex_model` says runs get "the strongest configured model".

**F4 (H): The prompt says to ask questions in the pane, but the operator reads the run screen.** "If you are
genuinely blocked … ask here and wait." The same prompt then says "the run screen shows the reports in order and
nothing else, so the operator reads them instead of this pane." A question asked only in the pane goes unseen.
Nothing says the question itself belongs in a `blocked` report's summary, and asking and then waiting without
reporting leaves Rails believing the session is still working.

**F5 (M): The instructions on merging to `main` conflict.**
- The prompt and CLAUDE.md say to push the branch, and that PRs are the operator's business.
- AGENTS.md says "a session (or the operator) may commit and merge straight into `main`" and "a session's own
  pushed branch may be merged directly into `main`".
- `WorktreeJanitor` treats a worktree whose HEAD is on `main` as releasable, which is consistent with either
  reading.

A session in this repo can reasonably conclude it should merge itself. This needs an operator decision (D1).

**F6 (M, this repo only): Stale root docs a session is likely to open.**
- `ARCHITECTURE.md` opens with "Rails owns orchestration state, planning, retries… one bounded planner decision,
  or one chaperone review… `agent_personas/`", and that directory no longer exists.
- `PLAN.md` covers a "reporter, curator, committer" refactor.
- `TODO.md` is about "worker containment".
- `COST_ANALYSIS.md` covers the headless-worker era.
- `TEST_COVERAGE_MATRIX.md` is likewise stale.

These are exactly the planner, step and worker concepts CLAUDE.md forbids, sitting at repo root with nothing
marking them as history.

**F7 (M, this repo only): The `bin/service restart` advice is wrong for a run session.** AGENTS.md says "Any agent
session (including this one) should run `bin/service restart` directly after a config change". A run session
works in a worktree. Restarting production reloads `main`'s code, not the worktree's, and briefly takes down the
`/mcp/run` endpoint the session reports through. The advice is valid for the operator's session in `main`, not
for a run session.

### Stale, wrong or inconsistent descriptions

**F8 (M): `record_workspace_env_var` describes the planner era.**
- "every future worker and start_run_command" is stale: there are no workers, and there is no
  `start_run_command` tool.
- It does not say that the variable takes effect only for **future** sessions, not the current one.
- `evidenceRef` is required and undescribed.
- It understates the secrets risk: the value is plain text in the DB and is injected into every future session's
  environment.

**F9 (M): The `write_workflow_artifact` description is inaccurate, and using the tool harms the worktree.**
- The description says it writes into "the workspace-declared artifact directory". Nothing is declared; the path
  is always `<worktree>/.workflow-orchestrator/artifacts/<run>/`, with a legacy `front/demo-output/agents-sdk`
  fallback.
- Only this repo gitignores `.workflow-orchestrator/`. In any other target repo, a write leaves untracked files,
  so `WorktreeJanitor` sees the worktree as dirty and keeps it forever, or the session commits the artifacts.
- The run screen does show artifacts (`collect_artifacts`), but nothing tells the session why it would ever write
  one. The tool comment itself says what matters goes in the report_idle summary.

**F10 (L): `list_runs` promises a pull request field.** The description says it includes the "pull request", but
`RunPresenter` has no PR field, and Rails does no PRs.

**F11 (L): `ping_tool` is noise in every session.** It is a health check for a transport migration ("real tools
land in this directory as the port from scripts/workflow-mcp-app.ts proceeds"), and it costs every session a
tool slot.

**F12 (L): Every tool requires `runId`, although the capability already determines it.** `SessionAuthorization`
rejects a mismatched `runId`, so the parameter only adds a way to fail, plus the prompt's "do not invent or alter
identity fields" paragraph. `read_workflow_artifact` does not call `SessionAuthorization` at all, and
`Run.find_or_create_for_bus!` will create placeholder runs for unknown ids.

### Wrapper-level problems

**F13 (M): The wrapper sends claude-only instructions to every driver.** The ToolSearch and deferred-tool paragraph
and the `mcp__workflow__` prefix are claude conventions. Codex and opencode have no ToolSearch and name tools
differently. `compose` already receives `session_driver:` and ignores it.

**F14 (M): Several things the session needs are missing.**
- **The base commit.** The branch is cut from *local* `main` at `run.base_sha`, which may be behind
  `origin/main`. The session is never told the base, and never told not to rebase or merge `main` unasked.
- **What `done` means when nothing changed.** Tasks like this audit, or "investigate X", may have nothing to
  commit. "Commit your work and push" plus "Before reporting done, commit and push" reads as mandatory.
- **The repo's instructions.** Nothing tells a claude session in an AGENTS.md-only target repo that AGENTS.md
  exists, and nothing states the precedence: the repo's conventions win for code, the run lifecycle wins for
  push, PR and reporting.
- **Where the push credentials come from.** `GH_TOKEN` and a credential helper are preset, with
  `GIT_TERMINAL_PROMPT=0`. If a push fails, the session should report `blocked` with the error rather than try to
  fix auth. At the moment it may try `gh auth login`, which hangs.
- **No PR and no main.** Beyond saying nothing about PRs, the wrapper should state "do not open a PR, do not push
  to main" (pending D1).
- **What a good checkpoint looks like.** This is covered, and the text is decent, but it appears twice (see F15).

**F15 (L): The wrapper duplicates itself.**
- The branch and worktree appear in both the identity section and the working-agreement section.
- The report_idle protocol is spelled out almost word for word in the prompt, the tool description and the summary
  parameter description. One copy in the prompt and one in the tool, each shorter, is enough.
- "Authoritative" and "do not invent or alter identity fields" are defensive text left over from the multi-worker
  bus era.

**F16 (L): Claude sessions carry skill-list noise.** A dozen synced consumer skills (docx, pptx, morning,
chrome-browser…) and the `ruby-lsp` plugin load in every claude run. This is harmless but costs context, and
Rails cannot control it without `--setting-sources` or a dedicated config dir. Leave it unless it becomes a
problem.

**F17 (L): `WORKFLOW_RUN_TOKEN` is exported to every driver's pane.** Only codex needs it
(`bearer_token_env_var`). Any subprocess, such as a test suite or a dev server, can read the capability. This is
low risk given the local, no-auth trust model, but it is unnecessary for claude and opencode.

### What is accurate and should stay

The wrapper's core lifecycle is current:
- the session owns the worktree;
- it pushes `workflow/<name>` itself;
- `report_idle` is a non-terminal checkpoint;
- the outcomes are done, blocked and failed;
- a report covers only its interval;
- a report must always be made before ending a turn.

The `report_idle` tool description matches `RunIdleReport`: nothing is pushed or torn down, and each report
creates a `RunCheckpoint`. `get_run` and `list_workspaces` are accurate. CLAUDE.md and AGENTS.md are current on
the session model, apart from F5 and F7 and the Commit & PR section (see §4.4). No live context mentions a
planner, steps or a GitHub question protocol except F3 (machine-global) and F6 (stale docs).

---

## 4. Proposed rework

### 4.1 What goes where

| Content | Home | Why |
|---|---|---|
| Run identity (runId, branch, worktree, base) | **Prompt** | Only Rails knows it. Every driver reliably sees a first user message. |
| Run lifecycle (push only this branch, no PR or main, report_idle when and how, questions go in `blocked`) | **Prompt**, short | It must work in every repo, for every driver, and before the model has looked at any tool. |
| How to call each tool and what its params mean | **MCP tool descriptions** | Read at the point of use. Shared tools must stay neutral about who is calling (run session or admin client). |
| A one-paragraph map of the server | **MCP server `instructions`** | Belt and braces for clients that surface it (Claude Code does; codex and opencode support is unverified). It must not be the only place the lifecycle lives. |
| How to build, test and commit *in this repo* | **Repo files** (AGENTS.md, CLAUDE.md) | Different per target repo, and the session reads them itself. Rails injects none of it. |
| workflow-orchestrator's architecture | **This repo's** AGENTS.md and CLAUDE.md only | Other target repos must never receive it. |
| Driver quirks (ToolSearch) | **Prompt, conditional on `session_driver`** | One line, for claude only. |

Rails-injected text must never mention herdr, Rails internals, `RunCheckpoint`, workflow-orchestrator or its
docs. Every one of those is meaningless in an arbitrary target repo.

### 4.2 Proposed task wrapper (full text)

Placeholders are in `{}`. Lines marked `[claude]` are emitted only for that driver, and the `## Attached files`
section only when there are attachments.

```text
# Run {run_id}

You are an agent session for one queued job in workspace `{workspace}`.

- Worktree: `{worktree}` — a git worktree only you are using.
- Branch: `{branch}`, created from local `main` at `{base_sha_short}`.

The repository's own instructions (AGENTS.md, CLAUDE.md, CONTRIBUTING, …) govern how you work on the code;
read them if your CLI has not already loaded them. The rules below govern this run and win where they differ.

## How this run works

- You own this job end to end: explore, edit, test and commit in this worktree without asking permission.
- If you changed anything, commit it and push this branch: `git push -u origin {branch}`. Git credentials are
  already configured; if a push fails, report `blocked` with the error instead of changing auth.
- Do not open a pull request, push to or merge into `main`, or rebase onto a newer `main` unless the task asks.
  The operator handles all of that.
- The operator can type into this terminal, but mostly reads your reports rather than watching it.

## Reporting

Call the `report_idle` tool (MCP server `workflow`) every time you stop and wait for the operator. Pass
runId `{run_id}`.
[claude] If it is not in your tool list, load it with ToolSearch: `select:mcp__workflow__report_idle`.

- `done`: the task is finished, with changes committed and pushed.
- `blocked`: you need a decision or something only the operator can give. Put the question in the summary,
  because a question asked only in this terminal may go unseen.
- `failed`: the task cannot be done as specified. Say why.

Reporting does not end the run or close anything. The operator may reply with more work; do it and report again.
Never end a turn without reporting, and never claim you reported if the call failed. Say it failed instead.

## Attached files

The operator attached these files, readable at `{attachments_dir}`: {names}.

# Task

{task}
```

About 1.7 KB before the task, down from 2.9 KB. What changed and why:

- One identity block, with the base commit added (F14, F15).
- Repo instructions are named generically, with an explicit precedence rule (F14, F5).
- Push and credentials guidance, and no PR, main or rebase (F14, F5). The main clause depends on **D1**.
- Questions go in the `blocked` summary (F4).
- The ToolSearch text is claude-only (F13).
- "Done" no longer implies a mandatory commit (F14).
- The detailed "what a good summary contains" moves to the tool's `summary` description, so it is read when
  writing one (F15).
- Attachments are given as a path, not a broken tool (F1). This needs the attachment fix in §4.5.

### 4.3 Proposed MCP text

**Server `instructions`** (`RunMcpServer.build(instructions: …)`, run endpoint only):

```text
Tools for an agent session running one orchestrator job. The job is yours; these tools cover only what the
orchestrator itself knows. report_idle is required: call it every time you stop working. The rest are optional:
queue_run, list_runs, get_run and list_workspaces spin off or inspect other jobs, and record_workspace_env_var
saves an environment fix for future jobs in this workspace. There is deliberately no tool for files, shell or
git; do those yourself in your worktree.
```

**`report_idle`** (run-only):

```text
description: Tell the operator you have stopped working and where things stand. Call it every time you go idle:
  `done` when the task is finished (commit and push first if you changed anything), `blocked` when you need the
  operator (put your question in the summary), or `failed` when the task cannot be done as specified (say why).
  It does not end the run, close your terminal or push anything. The operator reads these reports instead of
  your terminal, and may send more work; report again when you next stop.
runId: This run's id, from your startup prompt.
summary: A Markdown report of the work since your previous report only; earlier reports are kept, so do not
  repeat them. Cover what you changed and why, how you verified it (commands and results), what failed or was
  skipped, the branch state (pushed commit, anything uncommitted), and what should happen next. For `blocked`,
  start with the question you need answered.
```

**`queue_run`** (shared, caller-neutral; this fixes F2):

```text
description: Queue a separate job. It gets its own worktree, `workflow/<name>` branch and agent session, which
  pushes that branch when finished (no pull request is opened). It starts when a concurrency slot frees and shares
  none of your context, so write the task as a complete brief: goal, constraints, relevant files, and how to tell
  it worked. From inside a run, use it only for follow-up work the operator asked for, never to hand off your
  own task. Defaults to the calling run's workspace (or the default workspace from outside a run); pass workspace
  to target another.
driver: Which agent runs it (default claude).
```

**`list_runs`**: delete ", and pull request" from the description (F10). Everything else stays.

**`get_run`, `list_workspaces`**: no change.

**`record_workspace_env_var`** (F8):

```text
description: Save an environment variable that commands in this workspace need (e.g. a bundler workaround) so
  every future job in this workspace starts with it. It does not change your current session, so export it
  yourself as well. Recording a name again overwrites it. The value is set literally, never through a shell:
  pass a resolved value such as /tmp/bundler_gems, not $TMPDIR/bundler_gems or `cmd`. It is stored in plain text
  and injected into every future session, so never record a secret.
evidenceRef: One line on why it is needed, e.g. the failing command and its error.
```

**`ping_tool`**: remove from `RunMcpServer::TOOLS`. Keep it on the admin server if it is useful there (F11).

**`write_workflow_artifact` / `read_workflow_artifact`**: see **D2**. The recommendation is to remove both from the
run server.
- Rails reads nothing back from `write`, and it dirties target worktrees (F9).
- `read` is broken (F1).
- Launch attachments are better served as a plain path in the prompt.

If they are kept instead, fix `read`, move storage out of the worktree, and use these descriptions:

- `write_workflow_artifact`: "Save a file for the operator to view on this run's page (e.g. a long log or
  report too big for a summary). Stored outside your worktree and never committed."
- `read_workflow_artifact`: "Read part of a file attached to this run at launch. Start with the default
  window; request a later offset only if you need more."

### 4.4 Repo-file changes (this workspace only)

These are ordinary edits a later run can make. Rails injects none of them.

- **AGENTS.md**:
  - Resolve F5 per D1. Either delete "may commit and merge straight into `main`" and "may be merged directly into
    `main`", or scope them to the operator.
  - Scope the `bin/service restart` paragraph to the operator's own session in `main`, and state that run
    sessions must not restart the production instance (F7).
  - In "Commit & Pull Request Guidelines", drop "Run `bin/ci` before opening a PR" and the PR-description advice,
    or relabel it as guidance for the operator. Keep the commit-message style.
  - Remove the dangling `HANDOFF.md` reference, since the file does not exist.
- **CLAUDE.md**: replace "Read AGENTS.md before changing this repository" with an `@AGENTS.md` import. Claude then
  loads it just as codex and opencode do, and the duplicated paragraphs in CLAUDE.md can be cut down to the few
  claude-specific lines.
- **Stale root docs** (F6): delete `ARCHITECTURE.md`, `PLAN.md`, `TODO.md`, `COST_ANALYSIS.md` and
  `TEST_COVERAGE_MATRIX.md`, or move them to `docs/history/` with a one-line "historical, describes the removed
  planner architecture" header. Git history keeps them either way.
- **Delete** `.claude/skills/infrastructure/` and `.codex/skills/infrastructure/`. They contain no `SKILL.md`, so
  they are inert leftovers.

### 4.5 Code changes the rework implies (for a follow-up run)

1. `RunPrompt`:
   - replace the sections with §4.2, using `session_driver` for the claude line;
   - add `run.base_sha`;
   - pass the attachments dir.
2. `RunMcpServer.build`:
   - pass `instructions:`;
   - drop `PingTool` (and the artifact tools, per D2).
3. Tool descriptions per §4.3. Consider making `runId` optional and derived from the capability, which would let
   the prompt drop it (F12).
4. Attachments (F1):
   - store uploads outside any checkout, e.g. `storage/run_attachments/<run_id>/` or the runtime dir;
   - or copy them into the run's worktree at provision time under a path that is gitignored per-worktree
     through `.git/info/exclude`;
   - and give the session the absolute path.
5. Optional: pass `-c model_reasoning_effort=…` for codex (D4), and drop `WORKFLOW_RUN_TOKEN` from non-codex
   panes (F17).
6. Specs: extend `run_prompt` coverage for the driver branch and attachments, and add a spec for
   `read_workflow_artifact` (if kept) that would have caught F1.

### 4.6 Operator-machine changes (outside the repo)

- Rewrite or scope `~/.config/claude/projects/-Users-stockn-Source-workflow-orchestrator-main/memory/add-a-job-means-queue-run.md`
  so it applies only to the operator's own session in `main`. For example: "In the operator's session in the
  main checkout…; not applicable to a run session, which implements its task". Also fix the tool name, which is
  `mcp__orchestrator__…` in the admin server config and `mcp__workflow__…` in a run. Alternatively, disable
  auto-memory for run sessions from `SessionEnv`, but verify live which env var or setting does that first (D3).
- Delete `~/.config/codex/skills/bus-handoff/`.
- Consider whether codex's global `model_reasoning_effort = "low"` should apply to runs (D4).

---

## 5. Decisions for the operator

- **D1: May a run session merge into `main`?** The prompt and CLAUDE.md say push-only. AGENTS.md says a session may
  merge straight into `main`. The proposal assumes push-only ("do not push to or merge into main unless the task
  asks"). If sessions should be allowed to merge in some workspaces, that is a per-workspace setting, and it
  should be injected, not left to prose that differs between repos.
- **D2: Keep the artifact store?** The recommendation is to remove `write_workflow_artifact` and
  `read_workflow_artifact` from `/mcp/run`, and to deliver launch attachments as a filesystem path. The run page's
  artifacts panel would then only show launch files. The alternative is to fix `read`, move storage out of the
  worktree, and keep them.
- **D3: Auto-memory in run sessions.** Should claude runs load the operator's per-repo auto-memory at all? It is
  where F3's conflicting instruction comes from. Scoping the memory text is the minimal fix. Disabling it per
  session is the thorough one.
- **D4: Codex reasoning effort.** Runs currently inherit the global `low`. Should `SessionArgs` pin a higher effort
  for runs?
- **D5: How far to trim operator-global noise** (F16: synced skills and plugins in claude runs). The
  recommendation is to leave it unless it causes a problem. The alternative is a dedicated config dir or
  `--setting-sources`, which also changes what CLAUDE.md and settings load, so it needs a live check.

---

## Appendix: stale code comments (not context, but found on the way)

These never reach a session, but they describe the removed model and will mislead whoever edits the code next:

- `run_idle_report.rb`: "The run becomes terminal only when the operator publishes and that PR merges". Close
  session is what actually does it.
- `run_session_runner.rb#prompt!`: "the inbound path for a pull-request comment".
- `workspace_env_vars.rb`: "any worker", "WorkerSpawner", "start_run_command".
- `session_authorization.rb`: "Replaces WorkerAuthorization… per-step workers" (harmless history).
- `ping_tool.rb`: "as the port from scripts/workflow-mcp-app.ts proceeds".
- `artifact_store.rb`: `LEGACY_OUTPUT_DIR = front/demo-output/agents-sdk`, a path specific to one project that
  is baked into every workspace.

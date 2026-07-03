# Handoff: extracting the workflow orchestrator into its own repo

**Why this file exists:** this extraction was started by Claude Code in a session that ran low on
usage before finishing. Codex is picking up from here. This file is self-contained — you should
not need any other context to continue.

## Goal

Move the multi-agent workflow orchestration system (supervisor loop, orchestrator, planner,
workers, a shared JSON-file bus, and an MCP server exposing it all as tools) out of
`/Users/stockn/Source/simple-retail-planner/main/front/scripts/` into its own standalone sibling
repo at `/Users/stockn/Source/workflow-orchestrator` (this repo).

**Decided scope** (already confirmed with the user — do not re-litigate):
1. **Lift-and-shift as-is** — move the whole system, including retail-planner-specific bits
   (`demo_recorder`/`demo_verifier`/`front_fixer`/`back_fixer` roles, the plan templates in
   `workflow-mcp.ts`, the video-recorder/verifier agent prompts). Do **not** split into a
   generic-core/plugin architecture — that was explicitly rejected in favor of speed/simplicity.
2. New repo: sibling directory `/Users/stockn/Source/workflow-orchestrator` (this repo), package
   name `workflow-orchestrator`, fresh git repo (already `git init`'d, no commits yet).
3. Integration: `simple-retail-planner/main/front/package.json` adds a `file:` path dependency on
   this package. `simple-retail-planner`'s own `bin/` scripts become thin wrappers that delegate to
   the installed package's binaries.

Nothing in `front/src` or `back` (in simple-retail-planner) ever imports this system as a library —
it's invoked purely as a CLI/subprocess/MCP server. That's confirmed and makes the extraction safe
to do without untangling any app-code coupling.

## Key architectural concept: PKG_ROOT vs ROOT_DIR (target project root)

Before the move there was one `ROOT_DIR` conflating two things: where the code lives, and which
project it orchestrates (they were the same directory). After the move they diverge:

- **`PKG_ROOT`** — this package's own install location (`__dirname`-derived, e.g. finds this
  repo's own `bin/orchestrator_launcher`, `scripts/*.ts`, `node_modules/.bin/tsx`).
- **`ROOT_DIR`** (aka `WORKFLOW_TARGET_ROOT`) — the simple-retail-planner checkout being
  orchestrated (`front/`, `back/`, `front/demo-output/agents-sdk/`, `bin/record_demo`,
  `.claude/agents/`, `.codex/agents/`). Comes from the `WORKFLOW_TARGET_ROOT` env var, defaulting
  to `PKG_ROOT` for standalone dev/test runs of this package with no real target project.

Two things verified empirically in a throwaway sandbox before this work started (still true, no
need to re-verify):
- **`npm install` of a `file:` dependency does NOT install that dependency's own `dependencies`**
  — this repo needs its own independent `npm install` (already done — see Progress below).
- **Bash's `${BASH_SOURCE[0]}` does not resolve through symlinks.** Since npm's `file:` install
  creates a real symlink chain (`front/node_modules/workflow-orchestrator` → this repo, plus
  `front/node_modules/.bin/wf-*` → this repo's `bin/*`), every launcher's "find my own root" line
  must `realpath` the script path first, or it resolves to the wrong directory.

## Progress so far (what's already done — do not redo)

In **this repo** (`/Users/stockn/Source/workflow-orchestrator`), currently untracked, no commits yet:

1. ✅ Directory scaffolded: `scripts/`, `scripts/__tests__/`, `scripts/__tests__/helpers/`, `bin/`,
   `.claude/agents/`, `.codex/agents/`.
2. ✅ Copied (plain `cp`, not moved yet — originals still exist in simple-retail-planner):
   - 19 `.ts` files into `scripts/`: `agent-persona.ts, orchestrator-turn.ts, planner-turn.ts,
     supervisor-loop.ts, worker-turn.ts, workflow-bus-inspect.ts, workflow-bus.ts,
     workflow-log-reader.ts, workflow-logging.ts, workflow-mcp-app.ts, workflow-mcp-http.ts,
     workflow-mcp-server.ts, workflow-mcp.ts, workflow-state.ts, workflow-worker-logging.ts,
     workflow-worker-monitor.ts, workflow-worker-runtime-fake.ts, workflow-worker-runtime-node.ts,
     workflow-worker-runtime.ts`
   - 22 matching test files into `scripts/__tests__/` (see that directory for the exact list)
   - 2 helper files into `scripts/__tests__/helpers/`: `workflow-mcp-test-harness.ts`,
     `live-agent-mcp-config.ts`
   - Entire `.claude/agents/` (12 files) and `.codex/agents/` (10 files) directories
3. ✅ `package.json` written (name `workflow-orchestrator`, `bin` field mapping `wf-orchestrator`,
   `wf-orchestrator-claude`, `wf-supervisor`, `wf-supervisor-claude`, `wf-bus`, `wf-mcp-server`,
   `wf-mcp-http`, `wf-worker-follow`, `wf-worker-log`, `wf-workers` to the not-yet-created `bin/*`
   scripts; deps `@modelcontextprotocol/sdk@^1.29.0`, `zod@^4.3.6`; devDeps `tsx`, `typescript`,
   `@types/node`, `vitest`).
4. ✅ `tsconfig.json` written (plain Node/ESM, `include: ["scripts/**/*.ts"]`).
5. ✅ `vitest.config.ts` written (flat, `environment: 'node'`, `include:
   ['scripts/__tests__/**/*.test.ts']`).
6. ✅ `.gitignore` written (`node_modules/`).
7. ✅ `npm install` run successfully in this repo (143 packages, 0 vulnerabilities).
8. ✅ Fixed `ROOT_DIR`/`FRONT_DIR` in **this repo's** `scripts/workflow-mcp-app.ts` — now:
   ```ts
   export const ROOT_DIR = process.env.WORKFLOW_TARGET_ROOT
     ? path.resolve(process.env.WORKFLOW_TARGET_ROOT)
     : path.resolve(__dirname, '..')
   export const FRONT_DIR = path.resolve(ROOT_DIR, 'front')
   ```
9. ✅ Fixed `ROOT_DIR`/`PKG_ROOT`/`FRONT_DIR` in **this repo's** `scripts/supervisor-loop.ts` — now:
   ```ts
   const PKG_ROOT = path.resolve(__dirname, '..')
   const ROOT_DIR = process.env.WORKFLOW_TARGET_ROOT ? path.resolve(process.env.WORKFLOW_TARGET_ROOT) : PKG_ROOT
   const FRONT_DIR = path.resolve(ROOT_DIR, 'front')
   // ...
   const ORCHESTRATOR_LAUNCHER = resolveOrchestratorLauncher(process.env, PKG_ROOT) // was ROOT_DIR
   ```
10. ✅ Confirmed via grep: `agent-persona.ts`, `workflow-worker-runtime.ts`,
    `workflow-bus-inspect.ts`, `workflow-worker-monitor.ts` contain **zero** `__dirname`/`ROOT_DIR`
    self-computation — they already take `rootDir` as an explicit parameter from callers, so no
    changes needed in those 4 files. This was double-checked directly, not assumed.

**In progress / just discovered, NOT yet resolved:**

Ran `npx tsc -p tsconfig.json --noEmit` in this repo for the first time and got real type errors,
e.g.:
```
scripts/__tests__/agent-persona.node.test.ts(25,62): error TS2345: Argument of type 'FakeFileSystem' is not assignable to parameter of type 'PersonaFileSystem'.
scripts/__tests__/orchestrator-turn.node.test.ts(63,7): error TS2322: Type 'typeof import("fs")' is not assignable to type 'Pick<FileSystemAdapter, ...>'.
scripts/__tests__/worker-turn.node.test.ts(165,7): error TS2322: ...
```
(run the command yourself to see the full list — it was still printing when this handoff was written).

**Important context on this — verified, not a regression from the move:** simple-retail-planner's
own `front/tsconfig.json` has `"include": ["src", "mirage"]` — it **never included `scripts/` at
all**, so these test files were never typechecked by `npm run typecheck` in the old location
either. These are pre-existing, latent type errors in code that simply had no typecheck coverage
before, now surfaced for the first time because this repo's `tsconfig.json` legitimately includes
`scripts/**/*.ts`. **This is not something the extraction broke** — decide how to handle it (fix
the type errors properly, or loosen `tsconfig.json` to `noEmit`-check less strictly, or scope
`typecheck` to exclude test files, or just fix the actual type mismatches since they look narrow
and mechanical — e.g. `FakeFileSystem`/plain `fs` not matching an adapter interface that probably
just needs its parameter types widened to accept `PathLike`/generic signatures). Use your
judgment; this is a small side-fix, not a blocker to keep deferring.

## Remaining work (in order)

Original approved plan lives at `/Users/stockn/.config/claude/plans/cached-sniffing-sloth.md` on
this machine if you want the full original rationale — but everything actionable is repeated below.

### 3. (finish) Resolve the typecheck errors above, then confirm:
```bash
cd /Users/stockn/Source/workflow-orchestrator
npx tsc -p tsconfig.json --noEmit   # should be clean
npm test                             # all 22 moved vitest suites should pass under Node
```

### 4. Move + fix the `bin/*` launchers

Source files still live in `/Users/stockn/Source/simple-retail-planner/main/bin/`. Copy these into
this repo's `bin/` (they haven't been copied yet):
`orchestrator_launcher(.test.sh)`, `orchestrator_launcher_claude(.test.sh)`,
`supervisor_launcher(.test.sh)`, `supervisor_launcher_claude(.test.sh)`, `workflow_bus(.test.sh)`,
`workflow_mcp_http(.test.sh)`, `workflow_worker_follow(.test.sh)`, `workflow_worker_log(.test.sh)`,
`workflow_workers(.test.sh)`.

Plus create a **new** file with no prior equivalent (the old `.mcp.json` called `tsx` directly, no
wrapper script existed): `bin/workflow_mcp_server` + `bin/workflow_mcp_server.test.sh`, modeled on
`bin/workflow_bus`:
```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
PKG_ROOT="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
TSX_BIN="${TSX_BIN:-$PKG_ROOT/node_modules/.bin/tsx}"

if [[ ! -x "$TSX_BIN" ]]; then
  echo "Missing tsx binary at $TSX_BIN" >&2
  exit 1
fi

exec "$TSX_BIN" "$PKG_ROOT/scripts/workflow-mcp-server.ts" "$@"
```

Every moved script's root-resolution line changes from:
```bash
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
```
to the symlink-safe form:
```bash
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
PKG_ROOT="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
TARGET_ROOT="${WORKFLOW_TARGET_ROOT:-$PKG_ROOT}"
```
Then: `TSX_BIN`/`$PKG_ROOT/scripts/*.ts` references use `PKG_ROOT`; `WORKFLOW_STATE_DIR` defaults
(`front/demo-output/agents-sdk`) use `TARGET_ROOT`; the final `exec env ...
WORKFLOW_TARGET_ROOT="$TARGET_ROOT" ...` forwards it downstream.

`bin/orchestrator_launcher`'s dynamically-generated Codex profile TOML changes its
`[mcp_servers.workflow]` block to:
```toml
[mcp_servers.workflow]
command = "npx"
args = ["wf-mcp-server"]
cwd = "$TARGET_ROOT/front"
env = { WORKFLOW_TARGET_ROOT = "$TARGET_ROOT" }
```
(was `npx tsx scripts/workflow-mcp-server.ts` with `cwd = "$ROOT/front"`).

`bin/orchestrator_launcher_claude` additionally changes `cd "$ROOT"` → `cd "$TARGET_ROOT"` (using
the same `TARGET_ROOT="${WORKFLOW_TARGET_ROOT:-$PKG_ROOT}"` pattern) so Claude's cwd is the actual
simple-retail-planner checkout (where `.mcp.json`/`CLAUDE.md` live), not this package.

`.test.sh` fixes needed (mechanical `front/scripts/X.ts` → `scripts/X.ts` string substitutions in
existing assertions): `workflow_bus.test.sh`, `workflow_mcp_http.test.sh`, `workflow_workers.test.sh`,
`workflow_worker_log.test.sh`, `supervisor_launcher.test.sh`, `supervisor_launcher_claude.test.sh`.
No changes needed to `orchestrator_launcher.test.sh`, `orchestrator_launcher_claude.test.sh`, or
`workflow_worker_follow.test.sh` (their existing assertions remain valid since `TARGET_ROOT`
defaults to `PKG_ROOT` when unset).

`chmod +x` all the real launcher scripts (not the `.test.sh` files, though those can stay
executable too if copied with `cp -p`).

Verify: `npm run bin-tests` in this repo (runs all `bin/*.test.sh`) — should pass with
`WORKFLOW_TARGET_ROOT` unset (exercising the `PKG_ROOT` fallback).

### 5. Fix `.codex/agents/*.toml` (already copied into this repo, not yet edited)

Codex's `multi_agent` fan-out loads each subagent's own `.codex/agents/<role>.toml` directly
(including its own `[mcp_servers.workflow]` block) when the orchestrator spawns `planner`,
`demo_recorder`, etc. — **this is load-bearing, not dead config**, and must be fixed in all 8
files: `orchestrator.toml`, `planner.toml`, `demo_recorder.toml`, `demo_verifier.toml`,
`front_fixer.toml`, `back_fixer.toml`, `infra_fixer.toml`, `general_fixer.toml` (all currently
under `/Users/stockn/Source/workflow-orchestrator/.codex/agents/`).

Current (broken — points at a file that no longer exists at that path):
```toml
[mcp_servers.workflow]
command = "npx"
args = ["tsx", "scripts/workflow-mcp-server.ts"]
cwd = "/Users/stockn/Source/simple-retail-planner/main/front"
```
Fixed:
```toml
[mcp_servers.workflow]
command = "npx"
args = ["wf-mcp-server"]
cwd = "/Users/stockn/Source/simple-retail-planner/main/front"
env = { WORKFLOW_TARGET_ROOT = "/Users/stockn/Source/simple-retail-planner/main" }
```
Note: the hardcoded absolute `cwd` does **not** need to change — that directory isn't moving, only
the orchestrator tooling is. Only `args` (and the added `env`) need fixing. `npx wf-mcp-server`
will resolve from `cwd = .../front`'s own `node_modules/.bin/wf-mcp-server`, which exists once
step 6's `npm install` in `front/` creates that bin symlink.

Then, back in **simple-retail-planner** (`/Users/stockn/Source/simple-retail-planner/main`),
replace the real `.claude/agents` and `.codex/agents` directories with symlinks into this package
(do this only after confirming this repo's copies are correct and complete — do not delete the
originals until the new repo's copies are verified working, since simple-retail-planner's git
history still has these files if anything goes wrong):
```bash
cd /Users/stockn/Source/simple-retail-planner/main
rm -rf .claude/agents .codex/agents
ln -s ../front/node_modules/workflow-orchestrator/.claude/agents .claude/agents
ln -s ../front/node_modules/workflow-orchestrator/.codex/agents  .codex/agents
```
This requires step 6 (the `front/` `npm install`) to have already run, since the symlink target
(`front/node_modules/workflow-orchestrator/...`) won't exist until then. Do step 6 first, then this.

This also makes `bin/orchestrator_launcher_claude`'s `--agent demo-pipeline` resolve correctly
(Claude discovers `.claude/agents/*.md` relative to its cwd = `TARGET_ROOT`).

### 6. `simple-retail-planner/main/front/package.json` + thin wrapper scripts

Add dependency (exact relative path from `front/` to this sibling repo):
```json
"workflow-orchestrator": "file:../../../workflow-orchestrator"
```
Update the two existing scripts:
```json
"mcp:workflow": "wf-mcp-server",
"mcp:workflow:http": "wf-mcp-http",
```
Then:
```bash
cd /Users/stockn/Source/simple-retail-planner/main/front
npm install
```
This regenerates `package-lock.json` and creates the `node_modules/.bin/wf-*` symlinks. It does
**not** install this package's own deps — that's already done (step 7 above, "Progress so far").

Replace each of simple-retail-planner's 9 moved `bin/*` files (`bin/orchestrator_launcher`,
`bin/orchestrator_launcher_claude`, `bin/supervisor_launcher`, `bin/supervisor_launcher_claude`,
`bin/workflow_bus`, `bin/workflow_mcp_http`, `bin/workflow_worker_follow`,
`bin/workflow_worker_log`, `bin/workflow_workers`) with a 3-line delegate (a real file, not a
symlink — plain `dirname`/`BASH_SOURCE` is fine here since it's not going through npm's symlink
chain):
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec env WORKFLOW_TARGET_ROOT="$ROOT_DIR" "$ROOT_DIR/front/node_modules/.bin/wf-supervisor" "$@"
```
(swap the trailing `wf-*` binary name per file, matching the `bin` field in this repo's
`package.json`: `orchestrator_launcher`→`wf-orchestrator`,
`orchestrator_launcher_claude`→`wf-orchestrator-claude`, `supervisor_launcher`→`wf-supervisor`,
`supervisor_launcher_claude`→`wf-supervisor-claude`, `workflow_bus`→`wf-bus`,
`workflow_mcp_http`→`wf-mcp-http`, `workflow_worker_follow`→`wf-worker-follow`,
`workflow_worker_log`→`wf-worker-log`, `workflow_workers`→`wf-workers`).

This preserves every existing call site verbatim, including `bin/workflow_mcp_state`'s reference to
`bin/workflow_mcp_http` (that file itself is untouched — see "what stays behind" below). Delete the
corresponding 9 `.test.sh` files from simple-retail-planner's `bin/` — real coverage now lives in
this repo's `npm run bin-tests`.

Add to simple-retail-planner's `bin/setup` (after the existing `front`'s `npm ci`/`npm install`
block): a second `npm install` inside `../workflow-orchestrator` if that directory exists, plus
re-creating the two symlinks from step 5 (`ln -sfn`, idempotent, so a fresh clone of both repos
self-heals):
```bash
    echo "-> workflow-orchestrator dependencies"
    if [ -d "$ROOT_DIR/../workflow-orchestrator" ]; then
      (cd "$ROOT_DIR/../workflow-orchestrator" && npm install)
    else
      echo "   (skipped: /Users/stockn/Source/workflow-orchestrator not found)"
    fi

    echo "-> workflow agent symlinks"
    ln -sfn "$ROOT_DIR/front/node_modules/workflow-orchestrator/.claude/agents" "$ROOT_DIR/.claude/agents"
    ln -sfn "$ROOT_DIR/front/node_modules/workflow-orchestrator/.codex/agents"  "$ROOT_DIR/.codex/agents"
```

### 7. `simple-retail-planner/main/.mcp.json`

Before:
```json
{
  "mcpServers": {
    "workflow": {
      "command": "front/node_modules/.bin/tsx",
      "args": ["front/scripts/workflow-mcp-server.ts"]
    }
  }
}
```
After:
```json
{
  "mcpServers": {
    "workflow": {
      "command": "front/node_modules/.bin/wf-mcp-server",
      "args": [],
      "env": { "WORKFLOW_TARGET_ROOT": "/Users/stockn/Source/simple-retail-planner/main" }
    }
  }
}
```

### 8. Cleanup in simple-retail-planner

**Do this only after everything above is verified working** — don't delete the originals until
this repo's copies + wiring are confirmed functional end-to-end.

`git rm` (in `/Users/stockn/Source/simple-retail-planner/main`) the 19 moved `.ts` files under
`front/scripts/`, the 22 moved test files under `front/scripts/__tests__/`, the 2 moved test
helpers under `front/scripts/__tests__/helpers/`. (`.claude/agents`/`.codex/agents` are already
handled by step 5's `rm -rf` + symlink — git will show those as deleted-then-recreated-as-symlink.)

`git add` the updated `front/package.json`, `front/package-lock.json`, `.mcp.json`, `bin/*`,
`.claude/agents`, `.codex/agents` (git tracks the new symlinks as symlinks), `bin/setup`.

**Do not commit** — per this repo's `CLAUDE.md` convention, git commits require explicit user
direction; show the diff and ask before committing, in both repos.

## What stays behind in simple-retail-planner (do NOT move these)

`bin/record_demo`, `bin/server`, `bin/dev`, `bin/dev-portal`, `bin/render-dev-portal`, `bin/setup`,
`bin/test`, `bin/workflow_mcp_state`, `bin/workflow_mcp_state_ui` (+ their `.test.sh`),
`front/src/features/test/pages/McpStatePage.tsx` + `.test.tsx`, `front/vite.mcp-state.config.ts`,
`front/mcp-state/main.tsx` (the MCP state dashboard is coupled to `front/src`'s MUI theme/providers
/`@` aliases, and is a *consumer* of this system's data, not part of the system itself), and
`front/scripts/{record-demo,record-demo-config,record-demo-network,demo-reset,take-screenshots,
generate-voiceover,app-window-smoke,cursor-smoke,e2e-test}.ts` + their tests.

**Confirmed important:** `front/scripts/__tests__/` has three `*.node.test.ts` files that are
**not** part of this move and must keep working: `demo-reset.integration.node.test.ts`,
`record-demo-config.integration.node.test.ts`, `record-demo-network.node.test.ts`. Because of
these, **`front/vitest.config.ts`'s `node-worker-integration` project must NOT be deleted or
modified** — its glob (`scripts/__tests__/**/*.node.test.ts`) will just naturally match fewer files
after the move. No `front/vitest.config.ts` or `front/package.json` `"test"` script changes are
needed at all for this reason — confirmed by reading both files directly, don't second-guess this.

(Also FYI, unrelated to this task: zero `*.live.test.ts` files exist anywhere in the repo — the
`live-agent` vitest project is already vestigial dead config. Not your problem to clean up here.)

## Full verification checklist (run all of these before considering this done)

**In `/Users/stockn/Source/workflow-orchestrator` (this repo):**
1. `npm install` — no unmet dependency warnings.
2. `npm test` — all 22 moved vitest suites pass under Node.
3. `npm run typecheck` passes (see the "in progress" section above — resolve those errors first).
4. `npm run bin-tests` — all `bin/*.test.sh` pass standalone, with `WORKFLOW_TARGET_ROOT` unset.

**In `/Users/stockn/Source/simple-retail-planner/main`:**
5. `ls .claude/agents/demo-pipeline.md` and `ls .codex/agents/orchestrator.toml` resolve through
   the symlinks.
6. `front/node_modules/.bin/wf-supervisor --help` and `wf-orchestrator --help` resolve and run
   (confirms the `realpath` fix works against the *real* npm-installed symlink chain).
7. `bin/supervisor_launcher_claude --run-id=<test-run-id>` (thin wrapper) — confirms
   `WORKFLOW_TARGET_ROOT` threads through supervisor-loop → orchestrator_launcher_claude →
   `claude --agent demo-pipeline`, and `mcp__workflow__*` tools are visible to that agent.
8. `bin/orchestrator_launcher --run-id=<test> --task=... --scenario=both
   --frontend-url=http://localhost:5174` — exercises the Codex path, confirms bus/state files land
   under `front/demo-output/agents-sdk/` (the target project), not inside this package's checkout.
9. `bin/workflow_bus`, `bin/workflow_workers` — confirm state inspection still works.
10. `bin/workflow_mcp_state` still finds `bin/workflow_mcp_http` and renders live state.
11. `npm test` in `front/` — confirms remaining suites (including the 3 demo-recording node tests)
    still pass with the untouched `vitest.config.ts`.
12. `grep -rn "front/scripts/workflow\|front/scripts/supervisor\|front/scripts/orchestrator\|front/scripts/planner\|front/scripts/worker\|front/scripts/agent-persona" .`
    in simple-retail-planner returns nothing.

## When you're done

Report back what you did, what you verified, and any deviations from this plan (e.g. if the
typecheck errors needed a different fix than expected, or if `npm install` versions drifted). Do
not commit in either repo without explicit user approval — show diffs and ask first.

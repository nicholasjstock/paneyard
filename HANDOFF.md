# Handoff — 2026-07-04 session

## Commits made this session (all pushed to local `main`, not pushed to remote)

1. **`e4db5af`** — Capture real worker exit status; fix duplicate-recovery bug; preserve smoke test logs
   - Node process adapter now captures real child exit code/signal via the `exit` event, so `stopReason` says "exited cleanly (code 0)" instead of misclassifying every non-explicit stop as a crash based on log keyword-grepping.
   - Fixed a real dedup bug: a second, independent stall/dead-end later in the same run was being silently swallowed by the first recovery request's stale (but still "fulfilled") status. Fix scopes reuse to "still fulfilled by an *active* worker" for planner-role requests.
   - `bin/live_claude_workflow_smoke.sh` / `bin/live_codex_workflow_smoke.sh` now archive worker/planner logs + bus state to `.smoke-logs/<runId>/` before deleting the temp dir (previously destroyed the only forensic evidence on every run). Also fixed two pre-existing apostrophes-inside-embedded-JS bugs that were silently breaking `bash -n` on both scripts.

2. **`0d8904c`** — Suppress recovery-planner spawning while a blocking user question is open
   - `runOrchestratorTurn` now checks `listOpenUserQuestions()` before building any stall/dead-end recovery plan. A run with an open `blocking` question stays a no-op (`phase: 'blocked_on_user'`) instead of spawning a redundant recovery planner to re-investigate something already awaiting a human answer.
   - **Known gap, explicitly not fixed** (agreed with user — revisit only once parallel multi-scope work is actually in use): the check is scoped to the whole **run**, not to the specific stall's scope. If two genuinely independent things stall at once in the same run (possible via the `append_spawn_request` escape hatch), an open question about one would incorrectly suppress recovery for the other, unrelated one.

3. **`37cbb83`** — Add `answer_user_question` so a human answer can actually reach a planner
   - New bus method `answerUserQuestion()`, new `WorkflowUserQuestion.status: 'answered'` + `answeredBy`/`answeredAt`/`answerText` fields.
   - New MCP tools: `answer_user_question` (records an answer) and `list_user_questions` (all statuses, not just open — lets a planner discover a previously-answered question during recovery).
   - Planner docs (`.claude/agents/planner.md`, `.codex/agents/planner.toml`) updated to check `list_user_questions` during stall/dead-end recovery before re-diagnosing from scratch.
   - Answering a question automatically lifts the orchestrator's suppression from commit 2, for free — `listOpenUserQuestions()` naturally excludes anything no longer `'open'`.

All three commits: full test suite green (130 tests), typecheck clean.

## What was live-validated this session (not just unit tests)

Ran `bin/live_claude_workflow_smoke.sh` twice against real `claude`-driven workers/planners. Confirmed live:
- Sequential nextStep/followingSteps handoff works correctly across many ticks.
- Repeat-stall recovery now fires independently multiple times in one run (the bug fixed in commit 1) — 4 separate recovery cycles fired correctly in one run before this fix existed to prove the bug, then the fix was validated separately.
- A real recovery planner correctly escalated via `append_user_question` after two identical stalls, per its own stated "don't blind-retry a 3rd time" policy — but the very next orchestrator tick ignored that and spawned a redundant recovery planner anyway. That's what commit 2 fixes.
- **Full answer-question-recovery loop, validated live end-to-end**: resumed that exact stalled run (see "How to resume a dead run" below), answered its open blocking question via a direct `answerUserQuestion` call, and watched a fresh recovery planner (`planner-5`) spawn *automatically*, call `list_user_questions`, correctly incorporate the human's answer, and hand a concrete diagnostic task to a new worker (`worker-2`) — with zero manual intervention beyond recording the answer. This is commit 3, proven live, not just in tests.

## Open, unresolved problem: the actual recorder hang

This is the *real* underlying issue the whole investigation above was chasing, and it is **not fixed**. Current understanding, most-to-least confident:

1. **Original mystery** (still unexplained): `claude --agent worker --permission-mode bypassPermissions -p -- <prompt>` hung twice in a row with **zero output ever** (not even the required `[STATUS]` line) and **no `record_demo`/playwright child process** — meaning the CLI process got stuck in its own startup/session-establishment, before executing any tool call. The identically-invoked `planner` role (same launcher code path, same permission flags, differs only in `--agent <role>`) worked fine 7 times in the same run. Root cause unknown — candidate theories (untested): a hang in the `workflow` MCP server handshake specific to the worker role's tool set, or something in `/record-demo` skill loading. **Nobody has actually diagnosed why this happens.**

2. **A live diagnostic worker (`worker-2`) got further** on its 3rd attempt (spawned after the answer-loop above) by using non-default ports (frontend 5275, backend 3100, redis 6381) instead of the defaults — but never explained *why* it chose to do that, never diagnosed the #1 mystery, and never called `worker_turn` to report back (a distinct, real protocol violation — it just logged one `[WAITING]` line and let its session end). We don't know if #1 is fixed, coincidentally avoided, or unrelated to what it changed.

3. **New, real, reproducible bug found along the way**: `bin/record_demo`'s local-mode readiness check polls a **hardcoded `http://127.0.0.1:3000/up`**, ignoring a custom `BACKEND_PORT` env var. When `worker-2` set `BACKEND_PORT=3100`, the actual backend came up healthy on 3100, but the readiness poll kept hitting the wrong port (3000) and span forever. This is why the 3rd attempt's orphaned process was still stuck, unable to ever succeed, when the session ended. **This is a real, fixable bug in `bin/record_demo`** (in the target repo, `simple-retail-planner/main`, not in this `workflow-orchestrator` package) — not yet fixed.

**Net result across 3 attempts this session: zero successful end-to-end recordings.** What was gained is diagnosis, not a fix — a precisely-located, different bug (#3) instead of the original mystery (#1), which remains unexplained.

All processes from the live test (the resumed supervisor loop, orphaned `record_demo`, its custom-ported app stack) were killed cleanly before this handoff — nothing left running.

## Where to pick this up next

- The archived state for the fully-investigated original stall is at `.smoke-logs/live-claude-smoke-1783190174/` (gitignored, still on disk) — has full worker/planner logs, prompts, and bus history for everything described above.
- To actually make progress on the real bug, next session should probably:
  1. Fix `bin/record_demo`'s hardcoded port-3000 health check to respect `BACKEND_PORT` (small, concrete, in the target repo).
  2. Separately, actually investigate mystery #1 — e.g., spawn a bare `claude --agent worker --permission-mode bypassPermissions -p -- "say hello"` by hand (trivial prompt, no recording) and see if *that* also hangs. If it does, it's not task-specific and points hard at the launcher/MCP-handshake theory. If it doesn't, the hang is specific to something the worker persona/`/record-demo` skill does.
  3. Consider requiring workers to call `worker_turn` (or at least update `lastMessagePath`) before backgrounding a long-running command, so a "fire and forget" turn like `worker-2`'s doesn't leave the system blind.
- The known scope-granularity gap in commit 2 (item 2 above) — revisit once there's an actual case with multiple genuinely-parallel stalls to design against, rather than guessing now.

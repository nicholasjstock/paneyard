# Handoff — 2026-07-06 session

## What this session did

Ran a real, live, hands-off orchestrator test against `simple-retail-planner/main`: seeded a generic "record the phone demo, verify it, fix anything found" task and let the supervisor loop run unattended, specifically to see whether it could find and fix a real UI bug (a link that isn't styled/underlined as expected) with zero hints about where the bug is.

**What worked**: the orchestrator autonomously diagnosed a real infra problem (a stale, >1-day-old Rails process squatting on port 3000), fixed it, and successfully recorded a real 183-second phone demo — all without any hints from me. A verifier worker reviewed the recording and reported PASS.

**Where it fell short**: the verifier's checklist only checked "is this non-black, does it show progressive UI," never link/button styling, so it declared the demo done without ever hitting the underline issue. A follow-up run that explicitly pointed a planner at the existing recording plus this repo's own QA checklist (`.claude/agents/troubleshooting.md`'s "blue underlined link?" check) hung for 10+ minutes with zero output (see "Open, unresolved problem" below) — **the underline bug itself is still unfixed.**

Two real orchestrator bugs were found and fixed along the way (both merged into this session's work, full suite 131/131 green, `tsc --noEmit` clean):

1. **Supervisor loop never stopped once a run was actually done** (`scripts/supervisor-loop.ts`). The `while (keepRunning)` tick loop had no check at all for `phase === 'completed'` — so even in the fully-correct case (a planner legitimately decides `nextStep: null`), the loop would keep ticking forever. Observed live: 11 consecutive redundant recovery-planner spawns after the real task was already done, `tickCount` climbing past 388, only stopped by manually killing the process. Fixed by breaking out of the loop as soon as persisted `phase === 'completed'`.
2. **`list_user_questions` / `list_open_user_questions` crashed with an MCP output-schema validation error** (`scripts/workflow-bus.ts`). Any `WorkflowUserQuestion` persisted before the `answeredBy`/`answeredAt`/`answerText` fields existed (i.e. anything from before commit `37cbb83`) hydrates from disk with those keys `undefined`, not `null` — but the MCP output schema requires them present as `string | null`. Fixed by defaulting the three fields to `null` on load, matching the pattern already used for spawn-request fields. Regression test added reproducing the exact legacy-record shape.

## Open, unresolved problem: the hang mystery, now confirmed on the planner role too

This extends the same "actual recorder hang" problem flagged as unresolved in the 2026-07-04 session below — new evidence this session broadens it beyond the worker role.

**What happened**: after the first run's verifier passed without checking link styling, I seeded a second, narrower run asking a planner to re-examine the already-recorded frames against the repo's own QA checklist and fix any styling defect found. That planner (`claude --agent planner --permission-mode bypassPermissions -p -- <prompt>`) ran for **10.5+ minutes with zero output** — no `[STATUS]` line, no partial `workflow-plan.md`, not even the artifact directory created — before I killed it. `ps` showed it alive the whole time (`STAT=SNs`) but with negligible cumulative CPU (0.4–1.8% over 10+ minutes), i.e. it looks I/O/network-bound, not spinning.

**How this differs from / relates to the 2026-07-04 case**:
- The July 4 hang was on the **worker** role, doing a plain shell-command task (`bin/record_demo`) with **no image/multimodal content** in its prompt. The identically-invoked **planner** role worked fine 7 times in that same run — which is why the original theory leaned toward something worker-specific (MCP tool-set differences, or `/record-demo` skill loading).
- This session's hang was on the **planner** role — the role that was previously reliable. That weakens the "it's a worker-specific MCP handshake issue" theory, since the same failure mode now shows up on the other role.
- The one thing genuinely new and different about this planner's task, versus every other planner turn that succeeded quickly (1–4 min) in the same session: this was the first turn asked to **read multiple image files** (`frame_00X.png` stills from the recording) as part of a stricter visual QA pass, rather than just reasoning over text artifacts and bus state. That's a new, untested candidate theory: something about multimodal image-reading tool calls (not the role, not `/record-demo` specifically) may be the actual trigger.

**Still genuinely undiagnosed** — nobody has isolated the actual root cause. Candidate theories, most-to-least likely given this session's evidence:
1. **Multimodal/image-reading step** (new theory from this session) — the hang correlates with the one turn that required reading several PNGs, not with role or with `/record-demo`/skill loading.
2. MCP handshake/tool-set issue (original July 4 theory) — weakened but not eliminated, since this could still be an intermittent issue that happened to hit worker once and planner once, unrelated to task content.
3. `/record-demo` skill loading — effectively ruled out for *this* occurrence, since this planner task never invoked that skill at all.

**Suggested next diagnostic step** (same style as the July 4 suggestion, updated for this session's lead): spawn a bare, trivial prompt that does nothing but ask an agent (either role) to read 2–3 existing PNG files and describe them — no recording, no CSS fix, no other work — and see if *that alone* reproduces the hang. If it does, that isolates multimodal tool calls as the trigger, independent of role. If it doesn't, the image-reading theory is wrong and whatever's left in common between the two occurrences (both were real `claude -p --agent <role>` subprocess launches under this same launcher code path) becomes the next thing to narrow down.

Archived forensic state for this session's two runs (worker/planner logs, prompts, last-messages, bus state, orchestrator-state history) is at `.smoke-logs/underline-live-test-20260706/` and `.smoke-logs/underline-live-test-20260706-v2/` (gitignored, still on disk).

---

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

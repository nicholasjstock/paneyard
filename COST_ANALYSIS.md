# Why usage got burned fast — 2026-07-24 incident notes

## What happened

Four separate runs were launched from the ops UI within a 9-minute window:

| Run | Task (abbreviated) | Workers | Tracked cost |
|---|---|---|---|
| `run-20260724-120458-4780` | add artifacts to a launch task that all workers can access | 6 | $4.09 |
| `run-20260724-120858-bbb3` | integrate Q&A questions into the unified workflow tree | 8 | $4.11 |
| `run-20260724-121120-e26b` | remove the now-obsolete top-of-run-screen panel | 11 | $3.94 |
| `run-20260724-121348-9c64` | use branch name instead of full task text as the run title | 7 | $1.66 |

Total: 32 workers, ~$13.80 tracked cost. All four independently hit `waiting_on_capacity` almost immediately, then repeated the same burst pattern again at 16:01 UTC and 21:00 UTC as capacity slowly returned and got re-exhausted by the same four runs resuming together each time.

**The account is Claude Pro** — the smallest Claude Code usage pool. Everything that day (the four runs' 32 workers, an active Claude Code development session doing unrelated repo work, and several restarts of a live interactive terminal built during that session) drew from that one pool, because the orchestrator inherits the local machine's credentials.

## The real mechanism: concurrency, not per-task cost

Dollar cost per run looked moderate individually. The thing that actually exhausted a 5-hour usage window in ~16 minutes was **parallelism**: the four runs don't wait on each other, so their workers ran concurrently — peak 4 simultaneous Claude sessions at 12:14:22 UTC. Just the first burst (12:05–12:22 UTC, 8 workers) processed:

- 159,998 output tokens
- 14,678,273 cache-read tokens
- 673,494 cache-creation tokens
- **~15.5M tokens of total throughput in 16 minutes**

A usage-limit window is sized against sequential, human-paced usage. Four concurrent autonomous multi-turn agents will always produce numbers like this — it's not a bug, it's what the architecture does when you point it at four things at once.

## What "cache" actually is here (and why it doesn't save you from this)

Claude's API is stateless — there's no server-side memory between turns. Every tool-call turn in a worker's loop resends the *entire conversation so far* as the prompt, because that's the only way the model sees prior context. A worker doing 20 tool-call turns transmits the growing conversation 20 times.

Prompt caching is what keeps that affordable: if the resent prefix matches what was cached ~5 minutes ago, that portion bills as a cheap "cache read" (~1/10th full price) instead of fresh input. That's *why* $13.80 wasn't $100+.

What caching does **not** do is make the resend disappear, or count as zero against a usage-limit window. The tokens are still transmitted and processed — cache reads are a discount on cost, not a discount on throughput. So the mental model "I built my system on not needing to resend context" is the part worth correcting: you can't avoid resending context in a multi-turn tool-use agent. Caching only softens the price of doing so.

## Two real cost multipliers baked into the current design

1. **No cross-worker cache sharing.** Every worker is a separate `claude`/`codex` process (`--no-session-persistence`, `--session-id` fresh each spawn). Anthropic's prompt cache is scoped to one conversation — it does not carry over between different worker processes, even if they'd send byte-identical persona/instruction preambles. Six sequential workers in one run each pay full price to "cold start" that shared preamble (`.claude/agents/worker.md` alone is ~9.6KB) on their first turn.
2. **Pull-only shared context.** `Orchestrator::RunContext` / `RunContextEntry` already exists as a mechanism for workers to record and read what earlier workers in the same run discovered — but it's opt-in (`get_run_context` MCP tool), not auto-injected the way `workspace_memory_prompt` (durable *project*-level knowledge) already is. Workers routinely re-discover things a predecessor in the *same run* already knew.

## Levers to reduce cost, roughly ordered by how much they change the existing design

**In-design (no reliability trade-off):**
- Auto-inject a run-scoped context digest into every worker's opening prompt (same pattern as `workspace_memory_prompt`, sourced from `RunContext.snapshot`) so later workers in a run don't re-explore what earlier ones already found.
- Trim the always-resent persona preamble — it's paid at full price on every worker spawn regardless of task size.
- Widen `write_scope` per worker where reliability allows, to cover more per handoff and reduce the number of cold starts. Real trade-off against the bounded-step reliability model — a dial, not a free win.
- A concurrency cap/warning when launching a new run while others are already active. Doesn't reduce total tokens, but stops multiple runs igniting simultaneously and spreads cost over calendar time instead of hitting the rate-limit cliff in minutes.

**Changes the deliberate design (bigger lever, needs an explicit decision):**
- Let sequential workers within one run `--resume` the same underlying CLI conversation instead of each starting fresh (`--session-id` per spawn). This is now technically available — the terminal-session feature built this session already exercises `--resume`. It would let real prompt caching and full history carry across worker steps, eliminating both the cold-start tax and the need for context-digesting. But it directly contradicts the deliberate `--no-session-persistence` / "workers remain autonomous executors" choice in `AGENTS.md` — bounded, memory-free steps exist specifically so one worker's drift or confusion can't compound into the next. Trading that for cost savings is a reliability trade-off to make on purpose, not a bugfix.

## Bottom line

Nothing was broken. The orchestrator did exactly what it was built to do — run independent work in parallel, spawn fresh accountable workers per step, retry cleanly through a rate limit. The fast burn was the product of launching four heavy multi-worker tasks at once against a Claude Pro pool that also had other things drawing on it. The actionable levers are the run-scoped context digest (cheap, no trade-off) and, if wanted later, a concurrency cap — the session-resume idea is the biggest lever but is a genuine design decision, not a fix.

# Claude Project Guide

Read [AGENTS.md](./AGENTS.md) before changing this repository. It is the shared source of truth for structure, commands, testing, and orchestration behavior.

The most important architectural rule is that orchestration belongs to Rails. Do not recreate `.claude/agents/planner.md`, spawn a stateful planner process, or move queue coordination back into an agent loop. `PlannerDecisionJob` prepares a compact brief, requests one structured model response, and transactionally persists and dispatches the result.

Planner context expansion is explicit. A planner may return `needs_context` with a precise `contextRequest`; Rails resolves it and starts a fresh call with the accumulated requested context. The planner chooses `maxChars`, may follow `next_offset`, and may request as many distinct windows as needed. Only an identical repeated request is rejected because it cannot add information.

Planning starts on the smaller model. If the context is sufficient but the decision genuinely requires stronger reasoning, the planner returns `needs_stronger_model`; Rails reruns the same decision with the stronger model and records the promotion. Do not route every decision directly to the stronger tier.

Workers remain autonomous executors. A result beginning with `[DONE]` promotes an existing validated `followingSteps` item directly in Rails. `[BLOCKED]`, `[FAILED]`, or an exhausted queue triggers a bounded planner decision.

When changing orchestration, add RSpec service/job regression coverage, run `bundle exec rspec`, `bin/rubocop`, and `git diff --check`. Never use a live model call merely to test parsing or routing; inject or stub the planner runner.
## Chaperone

Diagnosis starts on the small worker model. Rails records outcomes under the planner-provided stable `lineageKey`. Repeated unsuccessful attempts in one lineage trigger a strong-model chaperone, which may continue small, promote the next attempt, or stop for user input.

The chaperone is intentionally isolated at `/mcp/chaperone` behind a short-lived review capability. Its API is curated observability—not database access—and is limited to compact workflow state, bounded run artifacts, and one decision submission. Do not add arbitrary SQL, model lookup, filesystem traversal, shell execution, or general orchestration tools to it.

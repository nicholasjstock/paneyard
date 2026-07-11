# Test Coverage Matrix

This matrix tracks what the repository currently exercises at the integration level and what still needs dedicated coverage.

## Scope Legend

- `Covered`: exercised by current RSpec system/integration tests
- `Partial`: some paths covered, important gaps remain
- `Missing`: no meaningful automated coverage yet

## Current Matrix

| Area | Status | Current Coverage | Main Gaps | Priority |
| --- | --- | --- | --- | --- |
| Workspace management UI | Covered | Create, empty state, delete empty workspace, refuse delete with runs | Validation edge cases, duplicate names/paths | Medium |
| Workspace-scoped runs UI | Covered | Run list, launch path, details navigation, live refresh, and kill-run flow | More validation/error-state coverage | High |
| Workspace-scoped workers UI | Covered | List, show detail/log, stop worker, empty state, live refresh | Concurrent stop/error cases | Medium |
| Workspace-scoped questions UI | Covered | List, answer, empty state, live refresh | Concurrent answers, validation failures | Medium |
| Workspace-scoped events UI | Covered | List filtered by workspace, empty state, live refresh | Event ordering under heavier churn | Medium |
| Run orchestration backend | Covered | Planner/worker/question/artifact/state/status MCP workflows plus stalled/blocked/stop failure paths | More retry and malformed-agent paths | High |
| Launch/stop job lifecycle | Partial | Integration covers successful launch/stop, launch failure, and stop-with-worker-failure handling | Real subprocess launch failures, zombie cleanup | High |
| Action Cable live updates | Covered | `js: true` system specs cover run details plus workspace runs/workers/questions/events refresh without manual reload | No token-backed live-agent browser coverage yet | High |
| Run details page | Covered | Discovery, section rendering, live updates, and kill-run flow | Empty/error states and richer operator workflows still need coverage | High |
| Live agent token tests | Partial | Dedicated live-agent specs exist outside the default green run | Regular CI gating, broader launcher assertions | High |
| Claude/Codex adapter boundary | Partial | Fake/live harnesses exercise most orchestration edges without external calls | Real CLI output quirks, malformed agent responses | Medium |

## Verified Green Baseline

The current non-live-agent integration baseline is:

```sh
bundle exec rspec spec/system spec/integration
```

Most recent result: `35 examples, 0 failures`.

## Next Recommended Additions

1. Add empty/error-state coverage on the run details page and workspace launch form.
2. Add retry/malformed-agent-path integration specs around worker spawning and planner/worker handoff corruption.
3. Decide whether token-spending `live_agent` specs should be opt-in smoke tests or part of a gated release suite.
4. Add browser coverage for operator workflows that mix live updates with manual actions across multiple pages.

# Codex Agent Messaging Protocol

Codex subagents in this repo should report progress with short structured lines, not prose-heavy status dumps.

Format:

```text
[TAG] key="value" key2="value2" msg="Short summary"
```

Use these tags:

- `[STATUS]` for progress updates
- `[BLOCKED]` when waiting on an external condition or another agent
- `[FAILED]` when the task cannot recover
- `[DONE]` when the task finishes successfully
- `[QUESTION_TO_USER]` when a child needs a user decision
- `[RECEIVE_MESSAGE]` when a parent records a child update
- `[TRANSITION]` when moving between major phases

Guidelines:

- Keep `msg` to one short sentence.
- Include artifact paths, timestamps, durations, and evidence paths when relevant.
- Prefer exact values over vague descriptions.
- Use plain prose only for the final synthesized handoff back to the parent agent.
- Route all user-facing questions and state synthesis through the orchestrator and the shared bus.
- Workers and orchestrators should read the bus before deciding whether they have pending work.
- Child agents should never rely on the user noticing raw logs; surface decisions explicitly with `[QUESTION_TO_USER]`.
- Do not emit `[DONE]` for verification if the artifact is blank, black, static, corrupted, unreadable, or otherwise unsupported by positive evidence.
- Emit an initial `[STATUS]` within 30 seconds of starting work.
- For any task that runs longer than 60 seconds, emit another `[STATUS]` at least every 60 seconds.
- If a child task shows no progress or no fresh evidence for 180 seconds, emit `[BLOCKED]` instead of waiting silently.

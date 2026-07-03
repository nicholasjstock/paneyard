---
name: agent-messaging-protocol
description: Structured messaging protocol for agent-to-agent communication
metadata:
  type: specification
model: haiku
---

# Agent Messaging Protocol

Subagents MUST use this structured format. User-facing communication should be routed through the active orchestrator, which serves as the shared state owner for the run.

## Message Format

```
[TAG] key1="value1" key2="value2" msg="Human-readable summary"
```

All messages are single-line, structured, machine-parseable.

## Message Types

### [STATUS]
Current progress in a workflow. No action needed from parent.

### [BLOCKED]
Cannot proceed. Waiting on external condition, another agent, or stuck.

### [FAILED]
Task failed permanently. Cannot recover.

### [DONE]
Task completed successfully.

### [QUESTION_TO_USER]
Child agents use this to request a user decision. The orchestrator is the preferred relay for the question.

### [TRANSITION]
Moving between major phases. Informational only.

### [SPAWN_AGENT]
Spawning a child agent. Report what and why.

### [RECEIVE_MESSAGE]
Received a message from another agent. Acknowledge it.

## Guidelines

1. Every message is an update.
2. Be specific, not vague.
3. Include evidence when blocked or failed.
4. Keep `msg` to one sentence.
5. Always include `msg`.


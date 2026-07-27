# Demo Execution Report

**Run ID:** run-20260727-081644-4302  
**Role:** demo  
**Worker:** 684a3c61-9e5f-45b1-9ee3-f3a1848d2a70  
**Timestamp:** 2026-07-27

## Status: READY

An existing workspace development server was reused; no duplicate server was started.

### Verification

- Listener found on port 3000.
- `GET http://127.0.0.1:3000/up` returned HTTP 200.
- Response included `X-Workflow-Service: workflow-orchestrator`.
- Response body was `{"status":"ok","service":"workflow-orchestrator"}`.

### Workflow bus limitation

The workflow MCP tools were not exposed in this session, so `list_run_commands`, `write_workflow_artifact`, and `complete_run_finalization` could not be invoked. This file was updated directly as a fallback; no source files were changed.

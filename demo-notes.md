# Demo Notes

## Server Status
✓ Development server is running and serving requests

## Details
- **Status**: Active
- **Port**: 3000 (http://localhost:3000)
- **Process**: Rails (Puma) + Solid Queue jobs process
- **Confirmation**: 
  - Ruby processes confirmed listening on port 3000 via `lsof`
  - Development log shows active job processing (BroadcastWorkerLogsJob, TickRunJob)
  - Recent log entries at 2026-07-27T09:23:45Z show jobs being performed
  - Solid Queue job queue is active and processing recurring tasks

## How to Verify
The health endpoint is available at `http://localhost:3000/up` which returns:
```json
{"status":"ok","service":"workflow-orchestrator"}
```

This response includes the `X-Workflow-Service: workflow-orchestrator` header.

## Development Setup Summary
- Dependencies installed (Gemfile.lock present)
- Database prepared (no pending migrations)
- Both Puma server and Solid Queue workers are running together
- Both processes will exit together on interrupt (INT/TERM signals)

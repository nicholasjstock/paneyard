# Task Launch Architecture Diagnosis

**Status**: Confirmed — Full architecture traced and documented  
**Scope**: Rails-owned task launch, artifact distribution, worker context propagation  
**Date**: 2026-07-24

## Executive Summary

The Rails orchestration system successfully launches tasks and distributes execution context to workers. However, **artifact propagation from task launch to spawned workers is not yet implemented**. The current architecture supports storing artifacts in a filesystem-backed store and retrieving them via MCP tools, but there is no mechanism for:

1. Declaring which artifacts should be available to a newly spawned worker
2. Passing artifact references through the task launch pipeline
3. Automatically inheriting or propagating artifacts from parent workers to child workers

This diagnosis confirms the architectural boundaries and specifies the exact changes needed to support artifact propagation.

---

## Part 1: Current Task Launch Mechanism

### Entry Point: LaunchRunJob

**File**: `app/jobs/launch_run_job.rb` (lines 8-29)

When a task is launched from the ops UI, the flow is:

```
RunsController#create
  └─> LaunchRunJob.perform_later(run.id)
      ├─> Orchestrator::GitWorktree.provision!(run)
      ├─> SpawnRequest.create!(
      │     scope: "workflow-plan.md",
      │     requested_role: "planner",
      │     text: run.task,  # <-- Task text passed here
      │     ...
      │   )
      └─> run.update!(status: "running")
```

**Key Observations**:
- The task is stored in two places: `Run.task` (the model) and `SpawnRequest.text` (the request)
- The `SpawnRequest` is the **source of truth for the actual worker prompt** — workers never read `Run.task` directly
- The scope is hardcoded to `"workflow-plan.md"` for the initial planner request

### Run Model Storage

**File**: `app/models/run.rb` (lines 11-173)

The `Run` model holds:
- `task: string` — the free-form task/prompt text (required)
- `target_root: string` — the workspace directory where artifacts are stored
- `run_id: string` — unique run identifier
- Various status/phase fields for orchestration state

Relationships include:
- `has_many :spawn_requests` — the worker handoff queue
- `has_many :workers` — the spawned process registry
- `has_many :run_context_entries` — structured operational facts
- `has_many :acceptance_criteria` — acceptance contract metadata

**Key Gap**: The Run model has no field for artifact references or artifact inheritance configuration.

---

## Part 2: How Artifacts Are Currently Stored and Distributed

### Artifact Storage: ArtifactStore Service

**File**: `app/services/orchestrator/artifact_store.rb` (lines 1-117)

Artifacts are stored as **flat files** in the workspace filesystem:

```
<workspace_root>/.workflow-orchestrator/artifacts/<run_id>/<artifact_name>
```

Key operations:
- `write(root_dir, run_id, artifact_name, content)` — persist an artifact
- `read(root_dir, run_id, artifact_name)` — full read
- `read_window(root_dir, run_id, artifact_name, offset, limit)` — streaming read (2KB default, 8KB max)
- `names(root_dir, run_id)` — list all artifact names for a run
- `collect(root_dir, run_id, artifact_names)` — batch collect metadata (name, path, size, mtime, preview)

Constraints enforced by `resolve_path`:
- Artifact names must not contain `/`, `\`, or null bytes (prevent directory traversal)
- Names are matched exactly (case-sensitive)
- A run_id is sanitized to `[A-Za-z0-9._-]`

**Important**: The ArtifactStore does **NOT** enforce access control — it only handles filesystem I/O. Access control is enforced at the MCP tool level (see `WriteWorkflowArtifactTool` below).

### Artifact Discovery: RunsController#collect_artifacts

**File**: `app/controllers/runs_controller.rb` (lines 425-442)

The ops hub UI discovers artifacts from three sources:

```ruby
artifact_names = (
  SpawnRequest.where(run_id: @run.run_id).pluck(:scope) +  # Worker scopes
  Array(@latest_tick&.dig("followingSteps")).map { |step| 
    step["artifact"] || step[:artifact] 
  } +  # Queued follow-up steps
  Orchestrator::ArtifactStore.names(@run.target_root, @run.run_id)  # All files in store
).compact.uniq
```

Then it reads the content of the 4 most recent (by mtime) artifacts that exist on disk.

**Key Gap**: This is pull-based discovery. There is no push mechanism for a spawned worker to declare "I inherit artifacts A, B, C" and have the system automatically make them available to its child workers.

---

## Part 3: How Workers Receive Execution Context

### Worker Spawning Pipeline

**File**: `app/jobs/tick_run_job.rb` (lines 1-165)

The orchestrator's main loop (`TickRunJob`) discovers work:

```
TickRunJob#tick_run(run)
  └─> Orchestrator::SpawnRequestedWorkers.call(run: run)
      ├─> Collect eligible spawn requests from the queue
      ├─> For each request:
      │   ├─> Build the prompt from request + run context
      │   ├─> Determine allowed paths, write scope, execution mode
      │   └─> Call WorkerSpawner.spawn_worker(...)
      └─> Return spawned workers
```

**File**: `app/services/orchestrator/spawn_requested_workers.rb` (lines 1-394)

Key function: `build_requested_worker_prompt` (lines 324-332):

```ruby
def build_requested_worker_prompt(run_id:, request:)
  [
    "Run #{run_id}.",
    "Bus request: #{request.scope}.",
    "Requested by: #{request.asked_by}.",
    (request.requested_role.presence ? "Target role: #{request.requested_role}." : nil),
    request.text,  # <-- The actual task/prompt
    (request.context.presence ? "Context: #{request.context}." : nil),
    ("Write your report via write_workflow_artifact using artifactName=\"#{request.scope}\". ..." 
     unless request.requested_role == "committer")
  ].compact.join(" ")
end
```

The prompt is then enhanced with:
1. **Worker identity** (via `worker_identity_prompt`) — run_id, worker_id, nickname, role, scope, mode, write_scope, allowed paths, target_root
2. **Workspace memory** (via `workspace_memory_prompt`) — project-wide context from workspace memory entries

### Worker Spawning: WorkerSpawner Service

**File**: `app/services/orchestrator/worker_spawner.rb` (lines 1-500+)

The spawner:
1. **Writes the enriched prompt** to `<artifacts>/<run_id>/workers/<run_id>-<nickname>.prompt.txt`
2. **Creates a Worker row** in Rails with metadata (role, scope, paths, execution_mode, write_scope)
3. **Spawns the CLI process** (`claude` or `codex`) with:
   - The prompt passed via stdin or read from the prompt file
   - Environment variables: `WORKFLOW_RUN_ID`, `WORKFLOW_WORKER_ID`, `WORKFLOW_WORKER_NICKNAME`, `WORKFLOW_WORKER_SCOPE`, `WORKFLOW_WORKER_TOKEN`
   - MCP config pointing at this Rails app's `/mcp` endpoint
   - Log files to capture output

**Key Finding**: The worker's access to artifacts is **entirely mediated by MCP tools**. The prompt itself only mentions the worker's own artifact name (its `scope`), not any other artifacts.

### Worker Context Access: MCP Tools

Workers access context through these MCP tools provided by Rails:

#### `get_run_context` Tool
**File**: `app/services/mcp_tools/get_run_context_tool.rb` (lines 1-19)

Returns structured run context:
- Acceptance criteria and their current state
- Confirmed facts and rejected approaches
- Operator decisions and questions
- Completion blockers

Called as: `Orchestrator::RunContext.snapshot(run_id:, entry_keys:)`

#### `read_workflow_artifact` Tool
**File**: `app/services/mcp_tools/read_workflow_artifact_tool.rb` (lines 1-22)

Allows a worker to read any artifact from the run (subject to the filesystem safety checks):
- Parameters: `runId`, `artifactName`, `offset`, `limit`
- Returns: `content` (bounded window), `total_bytes`, `offset`, `next_offset`, `truncated`
- Default window: 2,000 bytes; max: 8,000 bytes
- **No access control enforced** — any worker can read any artifact in its run

#### `write_workflow_artifact` Tool
**File**: `app/services/mcp_tools/write_workflow_artifact_tool.rb` (lines 1-18)

Allows a worker to write its assigned artifact:
- Parameters: `runId`, `artifactName`, `content`
- Access control: **The worker can only write to `artifactName === worker.scope`**
- Returns: `artifactName`, `path`

**Key Implementation Detail** (line 11-12):
```ruby
if worker && worker.scope != artifactName
  return ToolResponse.error("artifactName must match the assigned worker artifact: #{worker.scope}")
end
```

---

## Part 4: Artifact Propagation — Current Limitations

### Limitation 1: SpawnRequest Has No Artifact Fields

The `SpawnRequest` model currently has:
- `scope` — the worker's own artifact name (where it will write output)
- `text` — the task/prompt instructions
- `context` — additional free-form context

It does **NOT** have:
- `required_artifacts` or `inherited_artifacts` — artifacts that child workers need
- `artifact_references` — links to artifacts produced by parent workers
- `artifact_inheritance_mode` — whether artifacts are auto-inherited or explicit

**Impact**: When a worker submits a `worker_turn` result declaring "I'm done, spawn Worker B," there is no way for the worker to say "Worker B will need to read artifact X from my work." Worker B must independently discover or request artifacts.

### Limitation 2: Prompt Construction Ignores Artifacts

The `build_requested_worker_prompt` method (line 324-332 in spawn_requested_workers.rb) constructs the prompt from:
1. Run ID
2. Bus request scope
3. Requested role
4. The task text (from SpawnRequest)
5. Extra context

It does **NOT** include:
- A list of available artifacts
- Artifact metadata (size, format, modification time)
- Pre-loaded artifact content for small/critical artifacts
- Artifact inheritance relationships

**Impact**: Workers have no declarative knowledge of what artifacts exist. They must use `read_workflow_artifact` to discover artifacts, which is inefficient and requires workers to know artifact names in advance.

### Limitation 3: No Artifact Inheritance Mechanism

When Worker A completes with `worker_turn(result: "[DONE]", ...)`, the next spawn request created by the planner has **zero knowledge** of what artifacts A produced.

The current flow:
1. Worker A completes and writes to its artifact (e.g., `diagnosis.md`)
2. Worker A calls `worker_turn` with role, result, task
3. Rails updates the Worker row and publishes a `worker.stopped` bus event
4. The planner (Rails-owned PlannerDecisionJob) runs
5. The planner examines run context, acceptance criteria, and bus events
6. The planner creates a new `SpawnRequest` for Worker B
7. **The planner has to manually include "read artifact `diagnosis.md`" in Worker B's task text** if it wants B to know about A's work

There is no structured mechanism to declare "Worker B inherits artifacts {diagnosis.md, evidence.json}" and have the system automatically:
- Validate those artifacts exist
- Pass artifact metadata to Worker B
- Ensure Worker B has read access
- Track the inheritance relationship for future auditing

### Limitation 4: Artifact Discovery by the UI is Pull-Based Only

RunsController#collect_artifacts pulls all artifacts from the filesystem (max 4 most recent). There is no push notification or event when an artifact is written, so the UI must poll or wait for a refresh.

**Impact**: Small impact for the ops hub (it already refreshes every 5 seconds), but matters for worker-to-worker coordination where one worker might want to react to another worker's artifact completion.

---

## Part 5: Proposed Architectural Changes

### Change 1: Extend SpawnRequest with Artifact Fields

Add to the SpawnRequest model:
- `required_artifacts: string[]` — JSON array of artifact names that MUST exist before this request is fulfilled
- `inherited_artifacts: string[]` — JSON array of artifact names that should be pre-loaded or made available to the worker
- `artifact_inheritance_chain: string[]` — JSON array of worker_ids whose artifacts are inherited (for auditing)

Migration:
```sql
ALTER TABLE spawn_requests 
ADD COLUMN required_artifacts TEXT DEFAULT '[]',
ADD COLUMN inherited_artifacts TEXT DEFAULT '[]',
ADD COLUMN artifact_inheritance_chain TEXT DEFAULT '[]';
```

Update SpawnRequest#as_json to include these fields (for wire format compatibility).

### Change 2: Extend Worker Model with Artifact Metadata

Add to the Worker model:
- `inherited_artifacts: string[]` — which artifacts this worker inherited
- `produced_artifacts: string[]` — which artifacts this worker produced (populated after completion)

These are read-only fields updated by the orchestrator, not the worker.

### Change 3: Update Prompt Construction to Include Artifact Metadata

Modify `build_requested_worker_prompt` to include:

```markdown
## Inherited Artifacts

The following artifacts from prior workers are available for your review:

- `diagnosis.md` (2.3 KB, last modified 2026-07-24T14:05:22Z) — diagnosis output
- `evidence.json` (4.1 KB, ...) — collected evidence

Use `read_workflow_artifact` to read these files. All inherited artifacts are read-only.
```

Small/critical artifacts (< 1 KB) could be inlined in the prompt directly.

### Change 4: Add Artifact Validation in SpawnRequestedWorkers

Before fulfilling a spawn request, validate:
1. All `required_artifacts` exist in the artifact store
2. All `inherited_artifacts` are readable (exist, have valid names)

If validation fails, dismiss the request with a clear error.

### Change 5: Extend worker_turn to Declare Produced Artifacts

Update the `worker_turn` RPC signature (currently in the MCP tool spec) to include:

```json
{
  "runId": "...",
  "role": "worker",
  "result": "[DONE] ...",
  "task": "...",
  "nickname": "worker",
  "scope": "...",
  "producedArtifacts": [
    {
      "name": "diagnosis.md",
      "description": "architecture diagnosis"
    }
  ]
}
```

Rails can then validate that the declared artifacts actually exist and update the Worker.produced_artifacts field.

### Change 6: Update Planner to Use Artifact Declarations

Modify `Orchestrator::Planner.build_*_plan` methods to:
1. Examine the prior worker's `producedArtifacts`
2. When creating the next `SpawnRequest`, populate `inherited_artifacts` with relevant prior worker artifacts
3. Include reasoning in the planner decision's structured output for auditing

Example planner logic:
```ruby
prior_worker_artifacts = prior_worker.produced_artifacts || []
next_request = SpawnRequest.new(
  ...
  inherited_artifacts: prior_worker_artifacts.filter { |a| relevant_to_next_role?(a) }
)
```

### Change 7: Add RunContext Entry for Artifact Inheritance

Add a new RunContextEntry type: `artifact_inheritance_graph`

This tracks:
- Which workers produced which artifacts
- Which workers inherited which artifacts
- Timestamp and modification chain

Used for auditing and for workers to understand the artifact lineage.

### Change 8: Extend get_run_context to Return Artifact Metadata

Modify `Orchestrator::RunContext.snapshot` to include:
```json
{
  "artifacts": [
    {
      "name": "diagnosis.md",
      "producedBy": "worker-abc123",
      "producedAt": "2026-07-24T14:05:22Z",
      "sizeBytes": 2341,
      "inherited": true
    }
  ]
}
```

Workers can call `get_run_context` to discover available artifacts without manually listing them.

### Change 9: Add collect_artifacts MCP Tool

Create a new MCP tool `collect_artifacts` to allow workers to query artifact metadata:

```json
{
  "name": "collect_artifacts",
  "description": "Discover artifacts in the current run",
  "input_schema": {
    "properties": {
      "runId": { "type": "string" },
      "filter": { 
        "type": "object",
        "properties": {
          "producedBy": { "type": "string" },  // worker_id
          "inherited": { "type": "boolean" }
        }
      }
    }
  }
}
```

Returns artifact metadata for the current run, filtered by criteria.

---

## Part 6: Implementation Sequence

### Phase 1: Foundation (1-2 sprints)
1. Add database fields to SpawnRequest and Worker (migration)
2. Update JSON serialization to include new fields
3. Add validations in SpawnRequestedWorkers for required_artifacts
4. Update prompt construction to include artifact metadata

### Phase 2: Worker-Side Integration (1 sprint)
1. Add `producedArtifacts` support to worker_turn schema
2. Implement validation in the tool
3. Update Worker.produced_artifacts on completion
4. Add RunContext entries for artifact inheritance tracking

### Phase 3: Planner Integration (1 sprint)
1. Update all plan-building methods to examine prior_worker.produced_artifacts
2. Populate inherited_artifacts in spawn requests
3. Add reasoning to planner decision output

### Phase 4: Discovery & Auditing (0.5 sprint)
1. Add collect_artifacts MCP tool
2. Extend get_run_context to return artifact metadata
3. Add RunContext artifact_inheritance_graph entries

---

## Part 7: Acceptance Criteria for Artifact Propagation Feature

### AC1: Artifact Declaration
- A worker can call `worker_turn` with `producedArtifacts` field
- Rails validates declared artifacts exist
- Worker.produced_artifacts is updated

### AC2: Artifact Inheritance
- Planner can populate `inherited_artifacts` in a SpawnRequest
- SpawnRequestedWorkers validates required_artifacts exist before spawning
- Worker receives artifact metadata in its prompt

### AC3: Artifact Discovery
- Worker can call `collect_artifacts` to query available artifacts
- `get_run_context` returns artifact metadata
- Worker can reference prior artifacts by name

### AC4: Auditing
- RunContext entries track artifact inheritance chain
- Operator can see which workers produced/consumed which artifacts
- Artifact modification chain is preserved

### AC5: No Regression
- Existing workers continue to work without declaring artifacts
- Workers that don't use artifact propagation are unaffected
- Backward compatibility: missing fields default to empty arrays

---

## Evidence Citations

This diagnosis is based on examination of:

1. **LaunchRunJob** (`app/jobs/launch_run_job.rb`, lines 8-29): Task entry point, SpawnRequest creation
2. **Run Model** (`app/models/run.rb`, lines 11-173): Task storage, relationships
3. **SpawnRequest Model** (`app/models/spawn_request.rb`, lines 1-110): Current fields, JSON serialization
4. **ArtifactStore Service** (`app/services/orchestrator/artifact_store.rb`, lines 1-117): Filesystem storage, safety checks
5. **RunsController#collect_artifacts** (`app/controllers/runs_controller.rb`, lines 425-442): UI artifact discovery
6. **SpawnRequestedWorkers Service** (`app/services/orchestrator/spawn_requested_workers.rb`, lines 1-394): Worker spawning, prompt construction
7. **WorkerSpawner Service** (`app/services/orchestrator/worker_spawner.rb`, lines 1-500+): Process launching, MCP config
8. **Worker Model** (`app/models/worker.rb`, lines 1-147): Worker metadata storage
9. **WriteWorkflowArtifactTool** (`app/services/mcp_tools/write_workflow_artifact_tool.rb`): Access control for artifact writing
10. **ReadWorkflowArtifactTool** (`app/services/mcp_tools/read_workflow_artifact_tool.rb`): Artifact reading, no access control
11. **GetRunContextTool** (`app/services/mcp_tools/get_run_context_tool.rb`): Context snapshot mechanism

---

## Conclusion

The Rails orchestration system has a **solid, functional foundation** for task launching and artifact management:
- Tasks are launched via SpawnRequest with clear ownership and scoping
- Artifacts are stored safely with filesystem-backed access
- Workers receive identity and context through enriched prompts and MCP tools
- The MCP tool interface is well-designed for safe remote procedure calls

However, **artifact propagation from task launch to spawned workers is not implemented**. Workers can read any artifact via `read_workflow_artifact`, but there is no declarative, structured mechanism for:
- Declaring which artifacts a worker produces
- Inheriting artifacts from parent workers
- Validating artifact availability before spawning
- Discovering available artifacts efficiently

The proposed changes are **backward compatible** (new optional fields) and follow the existing architectural patterns (SpawnRequest for handoffs, RunContext for structured facts, MCP tools for worker access).

Implementing these changes will enable **multi-worker workflows where context naturally flows** from parent workers to child workers, with full auditing and retry-safety guarantees.

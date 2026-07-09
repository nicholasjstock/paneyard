import { railsGet, railsPost, type RailsApiRequestOptions } from './rails-api-client'
import type { OrchestratorDecisionState, OrchestratorTickHistory, WorkflowContext } from './workflow-mcp'

// HTTP-backed replacement for workflow-mcp.ts's JSON-file-backed
// readOrchestratorState/writeOrchestratorState/appendOrchestratorTickHistory/
// readOrchestratorTickHistory. Same signatures minus the `fileSystem` param
// (meaningless for an HTTP backend). WorkflowContext is still accepted
// (unread, prefixed `_`) purely so call sites don't need an `if` to build
// a different argument list per backend — switching backends is a single
// import swap.
//
// Api::OrchestratorTicksController#create upserts by (runId, tickCount)
// rather than strictly creating, so writeOrchestratorState and
// appendOrchestratorTickHistory -- always called back-to-back with the
// *same* state by every existing caller (workflow-mcp-app.ts,
// supervisor-loop.ts) -- safely collapse into a single row per tick
// instead of the two-files-two-writes shape the JSON backend needed.

export async function readOrchestratorState(
  _context: WorkflowContext,
  runId: string,
  options: RailsApiRequestOptions = {}
): Promise<OrchestratorDecisionState> {
  return railsGet<OrchestratorDecisionState>('/api/orchestrator_ticks/latest', { runId }, options)
}

export async function writeOrchestratorState(
  _context: WorkflowContext,
  state: OrchestratorDecisionState,
  options: RailsApiRequestOptions = {}
): Promise<string> {
  await postTick(state, options)
  return `rails:/api/orchestrator_ticks?runId=${encodeURIComponent(state.runId)}&tickCount=${state.tickCount}`
}

export async function appendOrchestratorTickHistory(
  _context: WorkflowContext,
  entry: OrchestratorDecisionState,
  options: RailsApiRequestOptions = {}
): Promise<string> {
  await postTick(entry, options)
  return `rails:/api/orchestrator_ticks?runId=${encodeURIComponent(entry.runId)}&tickCount=${entry.tickCount}`
}

export async function readOrchestratorTickHistory(
  _context: WorkflowContext,
  runId: string,
  options: RailsApiRequestOptions = {}
): Promise<OrchestratorTickHistory> {
  return railsGet<OrchestratorTickHistory>('/api/orchestrator_ticks/history', { runId }, options)
}

async function postTick(state: OrchestratorDecisionState, options: RailsApiRequestOptions): Promise<void> {
  await railsPost(
    '/api/orchestrator_ticks',
    {
      runId: state.runId,
      phase: state.phase,
      tickCount: state.tickCount,
      lastPlanSummary: state.lastPlanSummary,
      pendingSpawnKeys: state.pendingSpawnKeys,
      followingSteps: state.followingSteps,
      lastStallFinding: state.lastStallFinding,
    },
    options
  )
}

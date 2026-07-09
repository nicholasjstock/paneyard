module McpTools
  class WriteOrchestratorStateTool < MCP::Tool
    tool_name "write_orchestrator_state"
    description "Persist the orchestrator decision state for a run so the next orchestrator tick can continue from the prior decision context."
    input_schema(
      properties: {
        runId: { type: "string" },
        phase: { type: "string", enum: %w[starting planning waiting_on_workers stalled blocked_on_user completed] },
        tickCount: { type: "integer", minimum: 0 },
        lastPlanSummary: { type: [ "string", "null" ] },
        pendingSpawnKeys: { type: "array", items: { type: "string" } },
        followingSteps: {
          type: "array",
          items: {
            type: "object",
            properties: {
              owner: { type: "string" },
              artifact: { type: "string" },
              successCheck: { type: "string" }
            },
            required: %w[owner artifact successCheck]
          }
        },
        lastStallFinding: { type: [ "string", "null" ] },
        lastUpdatedAt: { type: [ "string", "null" ] }
      },
      required: %w[runId phase tickCount pendingSpawnKeys followingSteps]
    )

    def self.call(runId:, phase:, tickCount:, pendingSpawnKeys:, followingSteps:, server_context:,
                   lastPlanSummary: nil, lastStallFinding: nil, lastUpdatedAt: nil)
      state = {
        run_id: runId, phase: phase, tick_count: tickCount, last_plan_summary: lastPlanSummary,
        pending_spawn_keys: pendingSpawnKeys, following_steps: Orchestrator::WireFormat.underscore_keys(followingSteps),
        last_stall_finding: lastStallFinding, last_updated_at: lastUpdatedAt
      }
      saved = Orchestrator::TickState.write(state)
      ToolResponse.structured({ state_path: "orchestrator_ticks/#{runId}/#{tickCount}", state: saved })
    end
  end
end

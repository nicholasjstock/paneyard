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
        runId: runId, phase: phase, tickCount: tickCount, lastPlanSummary: lastPlanSummary,
        pendingSpawnKeys: pendingSpawnKeys, followingSteps: followingSteps.map(&:deep_symbolize_keys),
        lastStallFinding: lastStallFinding, lastUpdatedAt: lastUpdatedAt
      }
      saved = Orchestrator::TickState.write(state)
      ToolResponse.structured({ statePath: "orchestrator_ticks/#{runId}/#{tickCount}", state: saved })
    end
  end
end

module McpTools
  class RunOrchestratorTurnTool < MCP::Tool
    tool_name "run_orchestrator_turn"
    description "Run one orchestrator decision tick: inspect workers, detect stalls, ask the planner for the " \
      "next handoff, and publish worker jobs to the bus without spawning workers directly."
    input_schema(
      properties: {
        runId: { type: "string" },
        task: { type: "string" },
        scenario: { type: "string", enum: %w[admin phone both] },
        frontendUrl: { type: "string" },
        staleAfterMs: { type: "integer", minimum: 1 }
      },
      required: %w[runId task scenario frontendUrl]
    )

    def self.call(runId:, task:, scenario:, frontendUrl:, server_context:, staleAfterMs: nil)
      previous_state = Orchestrator::TickState.latest(runId)
      structured = Orchestrator::Turn.run_orchestrator_turn(
        run_id: runId, task: task, scenario: scenario, frontend_url: frontendUrl,
        stale_after_ms: staleAfterMs, previous_state: previous_state
      )
      Orchestrator::TickState.write(structured[:next_state])
      ToolResponse.structured(structured)
    end
  end
end

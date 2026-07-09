module McpTools
  class WorkerTurnTool < MCP::Tool
    tool_name "worker_turn"
    description "Report one worker turn result. Always requests a follow-up planner via a bus spawn request " \
      "(reusing an existing open or still-in-flight-fulfilled one, rather than duplicating it) with the result " \
      "and the current followingSteps queue as context, so the supervisor spawns it and that planner decides " \
      "the next nextStep/followingSteps via planner_turn -- worker_turn never publishes a plan or spawns a " \
      "process itself."
    input_schema(
      properties: {
        runId: { type: "string" },
        role: { type: "string", enum: %w[planner orchestrator worker] },
        nickname: { type: "string" },
        scope: { type: "string" },
        result: { type: "string" },
        task: { type: "string" },
        scenario: { type: "string", enum: %w[admin phone both] },
        frontendUrl: { type: "string" }
      },
      required: %w[runId role nickname scope result task scenario frontendUrl]
    )

    def self.call(runId:, role:, nickname:, scope:, result:, task:, scenario:, frontendUrl:, server_context:)
      previous_state = Orchestrator::TickState.latest(runId)
      structured = Orchestrator::Turn.run_worker_turn(
        run_id: runId, role: role, nickname: nickname, scope: scope, result: result, previous_state: previous_state
      )
      Orchestrator::TickState.write(structured[:next_state])
      ToolResponse.structured(structured)
    end
  end
end

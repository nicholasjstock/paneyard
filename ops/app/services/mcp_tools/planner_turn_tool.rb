module McpTools
  class PlannerTurnTool < MCP::Tool
    tool_name "planner_turn"
    description "Submit the planner's decision for a run: one nextStep to execute right now (or null if nothing " \
      "to do), plus the followingSteps queue for the next planner invocation to pick up once nextStep's worker " \
      "reports back. Publishes at most one spawn request (for nextStep) and persists followingSteps as " \
      "orchestrator state."
    input_schema(
      properties: {
        runId: { type: "string" },
        summary: { type: "string" },
        nextStep: {
          type: [ "object", "null" ],
          properties: {
            owner: { type: "string", enum: %w[orchestrator worker] },
            artifact: { type: "string" },
            successCheck: { type: "string" }
          },
          required: %w[owner artifact successCheck]
        },
        followingSteps: {
          type: "array",
          items: {
            type: "object",
            properties: {
              owner: { type: "string", enum: %w[orchestrator worker] },
              artifact: { type: "string" },
              successCheck: { type: "string" }
            },
            required: %w[owner artifact successCheck]
          }
        }
      },
      required: %w[runId summary nextStep followingSteps]
    )

    def self.call(runId:, summary:, nextStep:, followingSteps:, server_context:)
      previous_state = Orchestrator::TickState.latest(runId)
      next_step = nextStep&.deep_symbolize_keys
      following_steps = followingSteps.map(&:deep_symbolize_keys)
      structured = Orchestrator::Turn.run_planner_turn(
        run_id: runId, summary: summary, next_step: next_step, following_steps: following_steps, previous_state: previous_state
      )
      Orchestrator::TickState.write(structured[:nextState])
      ToolResponse.structured(structured)
    end
  end
end

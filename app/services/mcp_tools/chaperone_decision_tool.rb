module McpTools
  class ChaperoneDecisionTool < MCP::Tool
    tool_name "submit_chaperone_decision"
    description "Continue on the small model, promote this diagnosis lineage, or stop the current envelope. A stop with plannerTier and contextRequests replaces that envelope through one selected-tier planner; a stop without them asks the user. It never grants code or shell access to the chaperone."
    input_schema(
      properties: {
        action: { type: "string", enum: ChaperoneReview::ACTIONS },
        summary: { type: "string" },
        revisedInstruction: {
          type: [ "string", "null" ],
          description: "For continue_small/promote only: a replacement worker instruction to use for the retry " \
            "instead of repeating the original one verbatim. Use only when the attempts show a concrete, fixable " \
            "condition (wrong port, stale env, a missing prerequisite step) that the same instruction would just " \
            "hit again -- not for a plain reasoning retry."
        },
        plannerTier: {
          type: "string", enum: %w[small strong],
          description: "For stop only: request one bounded repair-planning turn. Choose small when the cited evidence makes the repair obvious; choose strong only when repair scope or tradeoffs need stronger reasoning."
        },
        contextRequests: {
          type: "array",
          description: "For a stop-triggered repair plan only: the minimum bounded artifact, run_context, or worker_log windows the planner needs. Arbitrary workspace files are not available to the chaperone.",
          items: {
            type: "object",
            properties: {
              source: { type: "string", enum: %w[artifact run_context worker_log] },
              reference: { type: "string" }, question: { type: "string" },
              offset: { type: [ "integer", "null" ] }, maxChars: { type: "integer" }
            },
            required: %w[source reference question maxChars]
          }
        }
      },
      required: %w[action summary]
    )

    def self.call(action:, summary:, server_context:, revisedInstruction: nil, plannerTier: nil, contextRequests: nil)
      review = ChaperoneReview.find(server_context[:review_id])
      review.record_tool_call!(tool_name)
      Orchestrator::ApplyChaperoneDecision.call(
        review:, action:, summary:, revised_instruction: revisedInstruction,
        planner_tier: plannerTier, context_requests: contextRequests
      )
      ToolResponse.structured(reviewId: review.review_id, action:, accepted: true)
    end
  end
end

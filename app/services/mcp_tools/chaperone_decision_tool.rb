module McpTools
  class ChaperoneDecisionTool < MCP::Tool
    tool_name "submit_chaperone_decision"
    description "Stop, continue on the small model, or promote this diagnosis lineage to the strong model."
    input_schema(
      properties: {
        action: { type: "string", enum: ChaperoneReview::ACTIONS },
        summary: { type: "string" }
      },
      required: %w[action summary]
    )

    def self.call(action:, summary:, server_context:)
      review = ChaperoneReview.find(server_context[:review_id])
      review.record_tool_call!(tool_name)
      Orchestrator::ApplyChaperoneDecision.call(review:, action:, summary:)
      ToolResponse.structured(reviewId: review.review_id, action:, accepted: true)
    end
  end
end

module McpTools
  class ReplyReceivedDecisionTool < MCP::Tool
    tool_name "submit_reply_received_decision"
    description "Classify the operator's reply to a plan-approval question as approved, explain (the plan stands, post this explanation and ask again), or revise (the plan is wrong, replan and ask again). Never grants code, shell, or filesystem access."
    input_schema(
      properties: {
        action: { type: "string", enum: ReplyReceivedReview::ACTIONS },
        summary: { type: "string" },
        explanation: {
          type: [ "string", "null" ],
          description: "Required for explain: the plain-language reply to post back to the operator defending the existing plan. Ignored for other actions."
        }
      },
      required: %w[action summary]
    )

    def self.call(action:, summary:, server_context:, explanation: nil)
      review = ReplyReceivedReview.find(server_context[:review_id])
      review.record_tool_call!(tool_name)
      raise ArgumentError, "explain requires an explanation" if action == "explain" && explanation.blank?

      Orchestrator::ApplyReplyReceivedDecision.call(review:, action:, summary:, explanation:)
      ToolResponse.structured(reviewId: review.review_id, action:, accepted: true)
    rescue ArgumentError, ActiveRecord::RecordNotFound => error
      ToolResponse.error(error.message)
    end
  end
end

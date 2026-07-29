module McpTools
  class ReplyReceivedStateTool < MCP::Tool
    tool_name "get_reply_received_state"
    description "Read the plan-approval or pull-request-review question this reply answers, its full original context, and the operator's reply text."
    input_schema(properties: {})

    def self.call(server_context:)
      review = ReplyReceivedReview.find(server_context[:review_id])
      review.record_tool_call!(tool_name)
      question = review.user_question

      ToolResponse.structured(
        review: { id: review.review_id, questionId: review.user_question_id, questionKind: question&.scope == "pull_request_review" ? "pull_request_review" : "plan_approval" },
        question: question && {
          text: question.text, context: question.context, askedAt: question.asked_at.iso8601(3)
        },
        objective: { task: review.run.task, phase: review.run.phase, summary: review.run.phase_summary },
        reply: {
          author: review.github_comment_author, body: review.github_comment_body
        }
      )
    end
  end
end

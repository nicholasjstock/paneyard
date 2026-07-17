module McpTools
  class ListUserQuestionsTool < MCP::Tool
    tool_name "list_user_questions"
    description "List recent user questions, optionally scoped to one run, including answered and dismissed questions."
    input_schema(
      properties: {
        runId: { type: "string" },
        limit: { type: "integer", minimum: 1, maximum: 50 }
      },
      required: []
    )

    def self.call(server_context:, runId: nil, limit: nil)
      scope = UserQuestion.order(asked_at: :desc)
      scope = scope.where(run_id: runId) if runId.present?
      ToolResponse.structured({ questions: scope.limit((limit || 20).to_i.clamp(1, 50)).map(&:as_json) })
    end
  end
end

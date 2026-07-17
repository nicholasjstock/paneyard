module McpTools
  class ListOpenUserQuestionsTool < MCP::Tool
    tool_name "list_open_user_questions"
    description "List recent open user questions, optionally scoped to one run."
    input_schema(
      properties: {
        runId: { type: "string" },
        limit: { type: "integer", minimum: 1, maximum: 50 }
      },
      required: []
    )

    def self.call(server_context:, runId: nil, limit: nil)
      scope = UserQuestion.open_only.order(asked_at: :desc)
      scope = scope.where(run_id: runId) if runId.present?
      ToolResponse.structured({ questions: scope.limit((limit || 20).to_i.clamp(1, 50)).map(&:as_json) })
    end
  end
end

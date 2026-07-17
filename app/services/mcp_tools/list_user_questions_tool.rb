module McpTools
  class ListUserQuestionsTool < MCP::Tool
    tool_name "list_user_questions"
    description "List compact recent user questions for one run, including answered and dismissed questions."
    input_schema(
      properties: {
        runId: { type: "string" },
        limit: { type: "integer", minimum: 1, maximum: 20 },
        includeDetails: { type: "boolean" }
      },
      required: %w[runId]
    )

    def self.call(server_context:, runId:, limit: nil, includeDetails: false)
      scope = UserQuestion.where(run_id: runId).order(asked_at: :desc)
      questions = scope.limit((limit || 5).to_i.clamp(1, 20))
      payload = includeDetails ? questions.map(&:as_json) : questions.map(&:as_diagnostic_json)
      ToolResponse.structured({ questions: payload })
    end
  end
end

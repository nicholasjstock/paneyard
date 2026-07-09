module McpTools
  class ListOpenUserQuestionsTool < MCP::Tool
    tool_name "list_open_user_questions"
    description "List every open user question across all runs."
    input_schema(properties: {}, required: [])

    def self.call(server_context:)
      ToolResponse.structured({ questions: UserQuestion.open_only.map(&:as_json) })
    end
  end
end

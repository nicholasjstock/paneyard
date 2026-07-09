module McpTools
  class ListUserQuestionsTool < MCP::Tool
    tool_name "list_user_questions"
    description "List every user question across all runs, including answered/dismissed."
    input_schema(properties: {}, required: [])

    def self.call(server_context:)
      ToolResponse.structured({ questions: UserQuestion.all.map(&:as_json) })
    end
  end
end

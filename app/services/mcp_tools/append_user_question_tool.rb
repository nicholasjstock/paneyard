module McpTools
  class AppendUserQuestionTool < MCP::Tool
    tool_name "append_user_question"
    description "Append a human-facing question to the bus."
    input_schema(
      properties: {
        runId: { type: "string" },
        askedBy: { type: "string" },
        scope: { type: "string" },
        text: { type: "string" },
        context: { type: "string" },
        priority: { type: "string", enum: %w[advisory blocking] },
        tags: { type: "array", items: { type: "string" } }
      },
      required: %w[runId askedBy scope text]
    )

    def self.call(runId:, askedBy:, scope:, text:, server_context:, context: nil, priority: nil, tags: nil)
      run = Run.find_or_create_for_bus!(runId)
      question = UserQuestion.create!(
        run_id: run.run_id,
        asked_by: askedBy,
        scope: scope,
        text: text,
        context: context,
        priority: priority.presence || "advisory",
        tags: tags || []
      )
      ToolResponse.structured(question.as_json)
    end
  end
end

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
      effective_priority = priority.presence || "advisory"
      if effective_priority == "blocking" && run.open_blocking_question?
        return ToolResponse.error("This run already has an open blocking question; wait for it to be answered before asking another.", code: "blocking_question_already_open")
      end

      question = UserQuestion.create!(
        run_id: run.run_id,
        asked_by: askedBy,
        scope: scope,
        text: text,
        context: context,
        priority: effective_priority,
        tags: tags || []
      )
      ToolResponse.structured(question.as_json)
    end
  end
end

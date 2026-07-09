module McpTools
  class AppendSpawnRequestTool < MCP::Tool
    tool_name "append_spawn_request"
    description "Append a worker/planner spawn request to the bus."
    input_schema(
      properties: {
        runId: { type: "string" },
        askedBy: { type: "string" },
        scope: { type: "string" },
        text: { type: "string" },
        context: { type: "string" },
        requestedRole: { type: "string" },
        priority: { type: "string", enum: %w[advisory blocking] },
        tags: { type: "array", items: { type: "string" } }
      },
      required: %w[runId askedBy scope text requestedRole]
    )

    def self.call(runId:, askedBy:, scope:, text:, requestedRole:, server_context:, context: nil, priority: nil, tags: nil)
      run = Run.find_or_create_for_bus!(runId)
      request = SpawnRequest.create!(
        run_id: run.run_id,
        asked_by: askedBy,
        scope: scope,
        text: text,
        context: context,
        requested_role: requestedRole,
        priority: priority.presence || "advisory",
        tags: tags || []
      )
      ToolResponse.structured(request.as_json)
    end
  end
end

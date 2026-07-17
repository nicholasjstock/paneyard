module McpTools
  class ListRecentEventsTool < MCP::Tool
    tool_name "list_recent_events"
    description "List the most recent bus events for one run, oldest to newest."
    input_schema(
      properties: {
        runId: { type: "string" },
        limit: { type: "integer", minimum: 1, maximum: 200 }
      },
      required: %w[runId]
    )

    def self.call(server_context:, runId:, limit: nil)
      count = (limit || 20).to_i.clamp(1, 200)
      events = BusEvent.where(run_id: runId).order(created_at: :desc).limit(count).to_a.reverse
      ToolResponse.structured({ events: events.map(&:as_json) })
    end
  end
end

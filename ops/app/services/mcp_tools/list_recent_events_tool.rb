module McpTools
  class ListRecentEventsTool < MCP::Tool
    tool_name "list_recent_events"
    description "List the most recent bus events, oldest to newest."
    input_schema(
      properties: {
        limit: { type: "integer", minimum: 1, maximum: 200 }
      },
      required: []
    )

    def self.call(server_context:, limit: nil)
      count = (limit || 20).to_i.clamp(1, 200)
      events = BusEvent.order(created_at: :desc).limit(count).to_a.reverse
      ToolResponse.structured({ events: events.map(&:as_json) })
    end
  end
end

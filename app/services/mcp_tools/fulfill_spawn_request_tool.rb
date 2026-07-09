module McpTools
  class FulfillSpawnRequestTool < MCP::Tool
    tool_name "fulfill_spawn_request"
    description "Mark a spawn request fulfilled."
    input_schema(
      properties: {
        requestId: { type: "string" },
        fulfilledBy: { type: "string" },
        fulfillmentNote: { type: "string" }
      },
      required: %w[requestId fulfilledBy fulfillmentNote]
    )

    def self.call(requestId:, fulfilledBy:, fulfillmentNote:, server_context:)
      request = SpawnRequest.find_by!(request_id: requestId)
      request.update!(status: "fulfilled", fulfilled_by: fulfilledBy, fulfilled_at: Time.current, fulfillment_note: fulfillmentNote)
      ToolResponse.structured(request.as_json)
    end
  end
end

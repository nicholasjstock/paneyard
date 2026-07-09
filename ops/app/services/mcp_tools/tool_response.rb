module McpTools
  # Shared response-building helper for every McpTools::*Tool -- mirrors
  # scripts/workflow-mcp-app.ts's tool handlers, which all returned
  # `{ content: [{type:'text', text: JSON.stringify(structuredContent)}],
  # structuredContent }`. Named ToolResponse (not Response) to avoid
  # shadowing MCP::Tool::Response, which McpTools::*Tool < MCP::Tool
  # subclasses would otherwise resolve to first via lexical scoping.
  module ToolResponse
    module_function

    # Tools build their result in plain Ruby snake_case internally --
    # camelizing happens once, right here, rather than tool authors having
    # to remember to do it themselves. Idempotent against hashes that are
    # already camelCase (e.g. a model's own #as_json), so callers never
    # need to think about which shape they're holding.
    def structured(payload)
      camelized = Orchestrator::WireFormat.camelize_keys(payload)
      MCP::Tool::Response.new(
        [ { type: "text", text: JSON.generate(camelized) } ],
        structured_content: camelized
      )
    end
  end
end

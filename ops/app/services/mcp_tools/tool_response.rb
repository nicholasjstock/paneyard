module McpTools
  # Shared response-building helper for every McpTools::*Tool -- mirrors
  # scripts/workflow-mcp-app.ts's tool handlers, which all returned
  # `{ content: [{type:'text', text: JSON.stringify(structuredContent)}],
  # structuredContent }`. Named ToolResponse (not Response) to avoid
  # shadowing MCP::Tool::Response, which McpTools::*Tool < MCP::Tool
  # subclasses would otherwise resolve to first via lexical scoping.
  module ToolResponse
    module_function

    def structured(payload)
      MCP::Tool::Response.new(
        [ { type: "text", text: JSON.generate(payload) } ],
        structured_content: payload
      )
    end
  end
end

module Orchestrator
  module ChaperoneMcpServer
    module_function

    # Deliberately capability-oriented. Never add generic SQL, model lookup,
    # filesystem traversal, command execution, or mutation tools here.

    TOOLS = [
      ::McpTools::ChaperoneStateTool,
      ::McpTools::ChaperoneReadArtifactTool,
      ::McpTools::ChaperoneDecisionTool
    ].freeze
    TOOL_NAMES = TOOLS.map(&:tool_name).freeze

    def build(server_context: nil)
      MCP::Server.new(
        name: "workflow-chaperone", title: "Workflow Chaperone", version: "0.1.0",
        server_context:,
        tools: TOOLS
      )
    end
  end
end

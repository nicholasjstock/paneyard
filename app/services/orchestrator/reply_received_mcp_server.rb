module Orchestrator
  module ReplyReceivedMcpServer
    module_function

    # Deliberately capability-oriented, same as ChaperoneMcpServer. Never add
    # generic SQL, model lookup, filesystem traversal, command execution, or
    # mutation tools here.

    TOOLS = [
      ::McpTools::ReplyReceivedStateTool,
      ::McpTools::ReplyReceivedDecisionTool
    ].freeze
    TOOL_NAMES = TOOLS.map(&:tool_name).freeze

    def build(server_context: nil)
      MCP::Server.new(
        name: "workflow-reply-received", title: "Workflow Reply Received", version: "0.1.0",
        server_context:,
        tools: TOOLS
      )
    end
  end
end

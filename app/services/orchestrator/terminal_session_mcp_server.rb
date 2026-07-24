module Orchestrator
  module TerminalSessionMcpServer
    module_function

    def build(server_context: nil)
      MCP::Server.new(
        name: "terminal-session", title: "Terminal Session Operations", version: "0.1.0",
        server_context:,
        tools: [
          ::McpTools::TerminalSessionStateTool,
          ::McpTools::TerminalSessionRunControlTool
        ]
      )
    end
  end
end

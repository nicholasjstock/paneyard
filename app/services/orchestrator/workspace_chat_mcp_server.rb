module Orchestrator
  module WorkspaceChatMcpServer
    module_function

    def build
      MCP::Server.new(
        name: "workspace-chat", title: "Workspace Chat Operations", version: "0.1.0",
        tools: [
          ::McpTools::WorkspaceChatStateTool,
          ::McpTools::WorkspaceChatRunControlTool,
          ::McpTools::WorkspaceChatAnswerQuestionTool
        ]
      )
    end
  end
end

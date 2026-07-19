module Orchestrator
  module WorkerMcpServer
    module_function

    def build(server_context:)
      MCP::Server.new(
        name: "workflow-worker",
        title: "Workflow Worker",
        version: "0.1.0",
        server_context:,
        tools: [
          ::McpTools::PingTool,
          ::McpTools::CollectWorkflowStateTool,
          ::McpTools::ReadWorkflowArtifactTool,
          ::McpTools::WriteWorkflowArtifactTool,
          ::McpTools::GetRunContextTool,
          ::McpTools::WriteScopedFileTool,
          ::McpTools::WorkerTurnTool
        ]
      )
    end
  end
end

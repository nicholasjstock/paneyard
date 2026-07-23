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
          ::McpTools::ListWorkersTool,
          ::McpTools::ListRecentEventsTool,
          ::McpTools::WriteScopedFileTool,
          ::McpTools::WorkerTurnTool,
          ::McpTools::StartRunCommandTool,
          ::McpTools::GetRunCommandTool,
          ::McpTools::ListRunCommandsTool,
          ::McpTools::ReadRunCommandLogTool,
          ::McpTools::StopRunCommandTool,
          ::McpTools::GetProjectMemoryTool,
          ::McpTools::RecordProjectSetupTool,
          ::McpTools::RecordProtectedPathsTool,
          ::McpTools::RecordTestPathsTool,
          ::McpTools::ReportFailedApproachTool,
          ::McpTools::SubmitAcceptanceVerificationTool,
          ::McpTools::CommitRunChangesTool
        ]
      )
    end
  end
end

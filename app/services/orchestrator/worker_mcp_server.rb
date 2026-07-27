module Orchestrator
  module WorkerMcpServer
    module_function

    def build(server_context:)
      worker = Worker.find_by(worker_id: server_context[:worker_id])
      tools = case worker&.role
      when "reporter"
        [ ::McpTools::PingTool, ::McpTools::WriteWorkflowArtifactTool, ::McpTools::GetRunAuditTool, ::McpTools::CompleteRunFinalizationTool ]
      when "curator"
        [ ::McpTools::PingTool, ::McpTools::WriteWorkflowArtifactTool, ::McpTools::SelectReviewAssetsTool, ::McpTools::CompleteRunFinalizationTool ]
      when "seeder"
        [
          ::McpTools::PingTool, ::McpTools::GetRunContextTool, ::McpTools::WriteScopedFileTool,
          ::McpTools::WriteWorkflowArtifactTool, ::McpTools::CompleteRunFinalizationTool
        ]
      when "demo"
        [
          ::McpTools::PingTool, ::McpTools::WriteWorkflowArtifactTool, ::McpTools::StartRunCommandTool,
          ::McpTools::StopRunCommandTool, ::McpTools::GetRunCommandTool, ::McpTools::ListRunCommandsTool,
          ::McpTools::ReadRunCommandLogTool, ::McpTools::CompleteRunFinalizationTool
        ]
      when "git"
        [
          ::McpTools::PingTool, ::McpTools::GetRunContextTool, ::McpTools::WriteWorkflowArtifactTool,
          ::McpTools::WorkerTurnTool, ::McpTools::FinalizeRunPublicationTool
        ]
      else
        ordinary_worker_tools
      end
      MCP::Server.new(
        name: "workflow-worker",
        title: "Workflow Worker",
        version: "0.1.0",
        server_context:,
        tools:
      )
    end

    def ordinary_worker_tools
      [
          ::McpTools::PingTool,
          ::McpTools::CollectWorkflowStateTool,
          ::McpTools::ReadWorkflowArtifactTool,
          ::McpTools::WriteWorkflowArtifactTool,
          ::McpTools::GetRunContextTool,
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
          ::McpTools::ReportFailedApproachTool,
          ::McpTools::SubmitAcceptanceVerificationTool
      ]
    end
  end
end

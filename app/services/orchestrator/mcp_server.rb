module Orchestrator
  # Builds the MCP::Server instance mounted at /mcp (see config/routes.rb) --
  # this is what worker/planner CLI subprocesses connect to over Streamable
  # HTTP, replacing scripts/workflow-mcp-server.ts's stdio server.
  module McpServer
    module_function

    def build
      MCP::Server.new(
        name: "workflow-orchestrator",
        title: "Workflow Orchestrator",
        version: "0.1.0",
        tools: [
          ::McpTools::PingTool,
          ::McpTools::PublishRunStatusTool,
          ::McpTools::AppendSpawnRequestTool,
          ::McpTools::AppendUserQuestionTool,
          ::McpTools::AnswerUserQuestionTool,
          ::McpTools::FulfillSpawnRequestTool,
          ::McpTools::ListOpenSpawnRequestsTool,
          ::McpTools::ListOpenUserQuestionsTool,
          ::McpTools::ListUserQuestionsTool,
          ::McpTools::ListRecentEventsTool,
          ::McpTools::ListWorkersTool,
          ::McpTools::PlanWorkflowIterationTool,
          ::McpTools::PublishPlannerJobsTool,
          ::McpTools::WorkerTurnTool,
          ::McpTools::PlannerTurnTool,
          ::McpTools::ReadOrchestratorStateTool,
          ::McpTools::ReadOrchestratorTickHistoryTool,
          ::McpTools::WriteOrchestratorStateTool,
          ::McpTools::SpawnWorkerTool,
          ::McpTools::StopWorkerTool,
          ::McpTools::CollectWorkflowStateTool,
          ::McpTools::ReadWorkflowArtifactTool,
          ::McpTools::WriteWorkflowArtifactTool,
          ::McpTools::GetRunContextTool,
          ::McpTools::RecordRunContextEntryTool,
          ::McpTools::GetProjectMemoryTool,
          ::McpTools::RecordProjectMemoryEntryTool
        ]
      )
    end
  end
end

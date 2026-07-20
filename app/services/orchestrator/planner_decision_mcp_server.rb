module Orchestrator
  module PlannerDecisionMcpServer
    module_function

    def build
      MCP::Server.new(
        name: "workflow-planner-decision", title: "Workflow Planner Decision", version: "0.1.0",
        tools: [ ::McpTools::SubmitPlannerDecisionTool ]
      )
    end
  end
end

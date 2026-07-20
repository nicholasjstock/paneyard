module Orchestrator
  module PlannerDecisionMcpServer
    module_function

    def build(server_context: nil)
      MCP::Server.new(
        name: "workflow-planner-decision", title: "Workflow Planner Decision", version: "0.1.0",
        server_context:, tools: [ ::McpTools::SubmitPlannerDecisionTool ]
      )
    end
  end
end

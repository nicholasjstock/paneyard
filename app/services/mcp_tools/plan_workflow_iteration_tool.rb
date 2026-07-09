module McpTools
  class PlanWorkflowIterationTool < MCP::Tool
    tool_name "plan_workflow_iteration"
    description "Generate the next workflow plan using the repo agent roles and artifact contract."
    input_schema(
      properties: {
        task: { type: "string" },
        verifierFinding: { type: "string" },
        stallFinding: { type: "string" }
      },
      required: %w[task]
    )

    def self.call(task:, server_context:, verifierFinding: nil, stallFinding: nil)
      structured = Orchestrator::Planner.plan_workflow_iteration(
        task: task, verifier_finding: verifierFinding, stall_finding: stallFinding
      )
      ToolResponse.structured(structured)
    end
  end
end

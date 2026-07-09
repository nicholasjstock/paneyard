module McpTools
  class PlanWorkflowIterationTool < MCP::Tool
    tool_name "plan_workflow_iteration"
    description "Generate the next workflow plan using the repo agent roles and artifact contract."
    input_schema(
      properties: {
        task: { type: "string" },
        scenario: { type: "string", enum: %w[admin phone both] },
        frontendUrl: { type: "string" },
        verifierFinding: { type: "string" },
        stallFinding: { type: "string" }
      },
      required: %w[task scenario frontendUrl]
    )

    def self.call(task:, scenario:, frontendUrl:, server_context:, verifierFinding: nil, stallFinding: nil)
      structured = Orchestrator::Planner.plan_workflow_iteration(
        task: task, scenario: scenario, frontend_url: frontendUrl,
        verifier_finding: verifierFinding, stall_finding: stallFinding
      )
      ToolResponse.structured(structured)
    end
  end
end

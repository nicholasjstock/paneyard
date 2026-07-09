module McpTools
  class PublishPlannerJobsTool < MCP::Tool
    tool_name "publish_planner_jobs"
    description "Run the planner and publish its worker jobs to the shared bus as spawn requests."
    input_schema(
      properties: {
        runId: { type: "string" },
        task: { type: "string" },
        scenario: { type: "string", enum: %w[admin phone both] },
        frontendUrl: { type: "string" },
        verifierFinding: { type: "string" },
        stallFinding: { type: "string" }
      },
      required: %w[runId task scenario frontendUrl]
    )

    def self.call(runId:, task:, scenario:, frontendUrl:, server_context:, verifierFinding: nil, stallFinding: nil)
      plan = Orchestrator::Planner.plan_workflow_iteration(
        task: task, scenario: scenario, frontend_url: frontendUrl,
        verifier_finding: verifierFinding, stall_finding: stallFinding
      )
      jobs = Orchestrator::Planner.publish_planner_jobs(run_id: runId, summary: plan[:summary], plan: plan)
      ToolResponse.structured({ summary: plan[:summary], jobs: jobs })
    end
  end
end

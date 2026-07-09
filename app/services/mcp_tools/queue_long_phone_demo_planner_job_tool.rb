module McpTools
  class QueueLongPhoneDemoPlannerJobTool < MCP::Tool
    tool_name "queue_long_phone_demo_planner_job"
    description "Queue an explicit planner job to create the long phone demo video without auto-restarting an idle run."
    input_schema(
      properties: {
        runId: { type: "string" },
        frontendUrl: { type: "string" },
        task: { type: "string" }
      },
      required: %w[runId frontendUrl]
    )

    def self.call(runId:, frontendUrl:, server_context:, task: nil)
      run = Run.find_or_create_for_bus!(runId)
      resolved_task = task&.strip.presence || "Create the long phone demo video."
      request = run.spawn_requests.create!(
        asked_by: "user",
        scope: "workflow-plan.md",
        text: resolved_task,
        context: "Plan the full worker chain needed to produce the long phone demo video against #{frontendUrl}. " \
          "Publish the next bounded handoff with planner_turn.",
        requested_role: "planner",
        priority: "blocking",
        tags: %w[planner phone-demo long-demo-video seed-job]
      )
      ToolResponse.structured(request.as_json)
    end
  end
end

module McpTools
  class QueueRunTool < MCP::Tool
    tool_name "queue_run"
    description "Queue a new run. This is the only way you can cause code to change -- you yourself cannot write " \
      "to any repository. A queued run gets its own git worktree, its own branch, and its own session, and ends " \
      "with that branch pushed for the operator to review (it does not open a pull request). It starts when a " \
      "slot frees, not immediately. Write the task the way you would brief a capable colleague who cannot ask " \
      "you a follow-up question: state the goal, the constraints, and how they will know it worked. Defaults to " \
      "the calling run's own workspace, or the oldest registered workspace if called from outside a run; pass " \
      "workspace to target a different one."
    input_schema(
      properties: {
        task: { type: "string" },
        workspace: { type: "string", description: "Workspace name to queue the run in." },
        driver: { type: "string", enum: Run::LAUNCHER_VARIANTS, description: "Which agent to run it with." }
      },
      required: %w[task]
    )

    def self.call(task:, server_context:, workspace: nil, driver: nil)
      raise ArgumentError, "task is required" if task.blank?

      target = WorkspaceResolution.resolve!(server_context:, workspace:)

      run = target.runs.new(
        run_id: "run-#{Time.current.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(2)}",
        task:, launcher_variant: driver.presence || "claude",
        target_root: target.source_root, status: "queued", launched_by: "mcp"
      )
      run.worktree_name = Orchestrator::GitWorktree.name_for(run)
      run.save!
      RunDispatchJob.perform_later

      ToolResponse.structured(
        run_id: run.run_id,
        workspace: target.name,
        status: run.status,
        queued_behind: target.runs.queued.where("created_at < ?", run.created_at).count,
        capacity: { limit: Orchestrator::RunConcurrency.limit, in_flight: Orchestrator::RunConcurrency.in_flight }
      )
    rescue ArgumentError, ActiveRecord::RecordInvalid => error
      ToolResponse.error(error.message)
    end
  end
end

module McpTools
  class QueueRunTool < MCP::Tool
    tool_name "queue_run"
    # Shared by /mcp/run and /mcp/admin, so the text must not assume which
    # kind of caller is reading it.
    description "Queue a separate job. It gets its own worktree, `paneyard/<name>` branch and agent session, " \
      "starts when a concurrency slot frees, and shares none of your context -- write the task as a complete " \
      "brief: goal, constraints, relevant files, and how to tell it worked. From inside a run, use it only for " \
      "follow-up work the operator asked for, never to hand off your own task. From inside a run, workspace " \
      "defaults to your own. From outside one it is required: call list_workspaces and pass the workspace " \
      "whose sourceRoot is the repository you mean, or, if none is, register it with register_workspace first."
    input_schema(
      properties: {
        task: { type: "string" },
        workspace: { type: "string", description: "Workspace name to queue the run in. Required from outside a run." },
        driver: { type: "string", enum: Run::LAUNCHER_VARIANTS, description: "Which agent runs it (default claude)." }
      },
      required: %w[task]
    )

    def self.call(task:, server_context:, workspace: nil, driver: nil)
      raise ArgumentError, "task is required" if task.blank?

      target = WorkspaceResolution.resolve!(server_context:, workspace:, explicit: true)

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

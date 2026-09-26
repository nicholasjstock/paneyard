module McpTools
  class QueueRunTool < MCP::Tool
    tool_name "queue_run"
    description "Queue a new run in this workspace. This is the only way you can cause code to change -- you " \
      "yourself cannot write to any repository. A queued run gets its own git worktree, its own branch, its own " \
      "session, and ends in a pull request for the operator to review. It starts when a slot frees, not " \
      "immediately. Write the task the way you would brief a capable colleague who cannot ask you a follow-up " \
      "question: state the goal, the constraints, and how they will know it worked."
    input_schema(
      properties: {
        task: { type: "string" },
        driver: { type: "string", enum: Run::LAUNCHER_VARIANTS, description: "Which agent to run it with." }
      },
      required: %w[task]
    )

    def self.call(task:, server_context:, driver: nil)
      raise ArgumentError, "task is required" if task.blank?

      chat = AdminChatAuthorization.chat!(server_context:)
      workspace = chat&.workspace || Workspace.default
      raise ArgumentError, "no workspace to queue a run in" unless workspace
      unless workspace.initialized?
        raise ArgumentError, "workspace #{workspace.name} has not finished its setup discovery yet"
      end

      run = workspace.runs.new(
        run_id: "run-#{Time.current.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(2)}",
        task:, launcher_variant: driver.presence || "claude",
        target_root: workspace.source_root, status: "queued", launched_by: "admin_chat"
      )
      run.worktree_name = Orchestrator::GitWorktree.name_for(run)
      run.save!
      RunDispatchJob.perform_later

      ToolResponse.structured(
        run_id: run.run_id,
        status: run.status,
        queued_behind: workspace.runs.queued.where("created_at < ?", run.created_at).count,
        capacity: { limit: Orchestrator::RunConcurrency.limit, in_flight: Orchestrator::RunConcurrency.in_flight }
      )
    rescue ArgumentError, ActiveRecord::RecordInvalid => error
      ToolResponse.error(error.message)
    end
  end
end

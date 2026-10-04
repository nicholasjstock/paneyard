module McpTools
  # Re-points or releases a queued run's `after` (Orchestrator::RunDependencies):
  # how the operator unblocks a run whose dependency failed or was stopped, or
  # was merged in a way git cannot see (squash, rebase).
  #
  # Admin-only, beside close_session and reopen_session: deciding a run may
  # start without the work it was queued to build on is the operator's call.
  class UpdateRunDependenciesTool < MCP::Tool
    tool_name "update_run_dependencies"
    description "Replace the runs a queued, never-launched run waits for (queue_run's after), validated as " \
      "queue_run validates them, cycles included. Pass after as an empty list to release it: it then starts " \
      "when a slot frees, from its base branch as it is. Only do this when the operator asks. workspace is required."
    input_schema(
      properties: {
        runId: { type: "string" },
        workspace: { type: "string", description: "Workspace name the run belongs to." },
        after: { type: "array", items: { type: "string" }, description: "runIds to wait for instead; empty releases the run." }
      },
      required: %w[runId workspace after]
    )

    def self.call(runId:, workspace:, after:, server_context:)
      run = WorkspaceResolution.run!(server_context:, run_id: runId, workspace:)
      if run.status != "queued" || run.branch_name.present?
        return ToolResponse.error("Run #{run.run_id} has already launched; only a queued run's dependencies can change.",
          code: "not_waiting")
      end

      dependencies = Orchestrator::RunDependencies.validate!(after, workspace: run.workspace, base_branch: run.base_branch, run_id: run.run_id)
      run.update!(dependency_run_ids: dependencies.map(&:run_id))
      RunDispatchJob.perform_later

      ToolResponse.structured(
        run_id: run.run_id,
        status: run.status,
        after: run.dependency_run_ids,
        dependencies: Orchestrator::RunDependencies.status(run)
      )
    rescue Orchestrator::RunDependencies::Invalid => error
      ToolResponse.error(error.message, code: "dependency_invalid")
    rescue ArgumentError, ActiveRecord::RecordInvalid => error
      ToolResponse.error(error.message)
    end
  end
end

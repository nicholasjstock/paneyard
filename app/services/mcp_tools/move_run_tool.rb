module McpTools
  # Move a run to another runner (machine) for an MCP client: the herdr
  # plugin's run screen ("Move to <runner>") or the operator's own agent.
  # Orchestrator::RunMove does the work.
  #
  # Admin-only, beside close_session and reopen_session: moving a run closes
  # its session and hands its work to another machine, which is the
  # operator's decision. A run session never gets it.
  class MoveRunTool < MCP::Tool
    tool_name "move_run"
    description "Move a run to another runner (machine; list_runners): close its session if it is idle, carry its " \
      "branch, uncommitted changes, untracked files and saved conversation transcripts to that runner's checkout, " \
      "and reopen it there (resuming its conversation if that CLI can, otherwise starting fresh with its task and " \
      "newest report). Nothing is committed or pushed. A session still working is refused unless force is true, " \
      "which closes it mid-turn. The worktree it leaves behind is removed only if its work is saved; otherwise it " \
      "is kept. Only do this when the operator asks. workspace is required."
    input_schema(
      properties: {
        runId: { type: "string" },
        workspace: { type: "string", description: "Workspace name the run belongs to." },
        toRunner: { type: "string", description: "Name of the runner to move it to (list_runners)." },
        force: { type: "boolean", description: "Move it even though its session is still working. Default false." }
      },
      required: %w[runId workspace toRunner]
    )

    def self.call(runId:, workspace:, toRunner:, server_context:, force: false)
      run = WorkspaceResolution.run!(server_context:, run_id: runId, workspace:)
      moved = Orchestrator::RunMove.call(run, to: toRunner, force: force == true)
      run.reload

      ToolResponse.structured(
        run_id: run.run_id,
        status: run.status,
        from: moved.fetch(:from),
        runner: moved.fetch(:to),
        worktree: moved.fetch(:worktree),
        branch: run.branch_name,
        # SessionClose's outcome, when it was live: { outcome, worktree }.
        closed: moved[:closed]&.slice(:outcome, :worktree, :error),
        # The worktree left on the runner it left: removed (its work was
        # saved), kept, none (it had none by then), or error.
        source_worktree: { path: moved.fetch(:move).source_target_root, state: moved.fetch(:source_worktree),
                           error: moved[:source_worktree_error] }.compact,
        transferred: moved.fetch(:transferred).except("fingerprint"),
        # kept (the moved worktree) once queued again; nil with reopenError.
        reopened: moved[:reopened]&.fetch(:worktree),
        reopen_error: moved[:reopen_error],
        resume_note: "The session resumes the agent's conversation there when its CLI can find it (confirmed for " \
          "claude; untried for codex); if it cannot, it starts fresh with the task and newest report."
      )
    rescue Orchestrator::RunMove::NotMovable => error
      ToolResponse.error(error.message, code: "not_movable")
    rescue Orchestrator::RunMove::Failed => error
      ToolResponse.error(error.message, code: "move_failed")
    rescue ArgumentError => error
      ToolResponse.error(error.message)
    end
  end
end

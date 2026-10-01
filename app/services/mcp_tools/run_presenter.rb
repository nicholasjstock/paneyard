module McpTools
  # Shared shape for how a run is described to MCP callers. One place, so
  # `list_runs` and `get_run` can never drift into disagreeing about what a
  # run's state is.
  module RunPresenter
    module_function

    def summary(run)
      session = run.latest_session
      {
        run_id: run.run_id,
        status: run.status,
        task: run.task.to_s.squish.truncate(160),
        driver: run.launcher_variant,
        branch: run.branch_name,
        session: session && session_summary(session),
        started_at: run.started_at&.iso8601,
        stopped_at: run.stopped_at&.iso8601
      }.compact
    end

    def detail(run)
      summary(run).merge(
        task: run.task,
        worktree: run.target_root,
        worktree_name: run.worktree_name,
        launch_error: run.launch_error,
        launched_by: run.launched_by,
        # The run's own history: one Markdown report per time its session went
        # idle, oldest first, so the last entry is where the run stands now.
        checkpoints: run.checkpoints.map do |checkpoint|
          { at: checkpoint.created_at.iso8601, outcome: checkpoint.outcome, summary: checkpoint.summary }
        end
      ).compact
    end

    def session_summary(session)
      {
        status: session.status,
        # herdr's own view of what the agent is doing right now
        # (idle/working/blocked/done), as opposed to our bookkeeping status.
        agent_status: session.agent_status,
        live: session.live?,
        outcome: session.outcome,
        result: session.result,
        pane: session.herdr_pane_id,
        # The run's own herdr workspace, which is how the herdr plugin tells
        # that an action was invoked from inside this run.
        herdr_workspace: session.herdr_workspace_id,
        last_seen_at: session.last_seen_at&.iso8601
      }.compact
    end
  end
end

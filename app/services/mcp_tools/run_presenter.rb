module McpTools
  # Shared shape for how a run is described to the admin chat. One place, so
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
        recent_events: run.bus_events.order(created_at: :desc).limit(10).map do |event|
          { at: event.created_at.iso8601, type: event.event_type, payload: event.payload }
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
        last_seen_at: session.last_seen_at&.iso8601
      }.compact
    end
  end
end

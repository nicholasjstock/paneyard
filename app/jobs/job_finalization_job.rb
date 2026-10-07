class JobFinalizationJob < ApplicationJob
  queue_as :default
  retry_on Orchestrator::Runner::Error, wait: 30.seconds, attempts: 5

  def perform(session_id)
    session = RunSession.find_by(id: session_id)
    return unless session&.finalization_ready_at

    run = session.run
    failure = nil
    run.with_lock do
      session.reload
      return if session.finalization_completed_at
      # A reopened session owns this worktree now; never close or reclaim it.
      if (session.ended? && run.status.in?(%w[queued launching])) || run.latest_session.id != session.id
        session.update!(finalization_completed_at: Time.current, finalization_error: "Superseded by a reopened session; worktree kept.")
        return
      end

      if session.live?
        # Recheck just before shutdown: later edits or branch changes must not
        # turn a previously accepted request into lost work.
        Orchestrator::JobFinalization.validate!(run)
        released = Orchestrator::SessionClose.call(run, strict_workspace: true, finalizing: true)
        raise Orchestrator::Runner::Error, released[:error] if released[:worktree] == "error"
      else
        Orchestrator::RunCompletion.call(run:, outcome: "done", summary: session.result) if run.active?
        runner = Orchestrator::Runner.for(run.workspace)
        runner.close_workspace!(session.herdr_workspace_id) if session.herdr_workspace_id.present?
        if runner.worktree_registered?(repository_path: Orchestrator::WorktreeJanitor.repository_for(run), path: run.target_root)
          Orchestrator::JobFinalization.validate!(run)
          Orchestrator::WorktreeJanitor.release!(run, finalizing: true)
        end
      end
      session.update!(finalization_completed_at: Time.current, finalization_error: nil)
    rescue Orchestrator::Runner::Error => error
      # Commit the ended session/slot even when cleanup failed after shutdown.
      session.update!(finalization_error: error.message)
      failure = error
    end
    raise failure if failure
  end
end

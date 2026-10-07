module Orchestrator
  # Acceptance is durable, but shutdown is armed only after Rack closes the
  # response body. An interrupted response may be retried with the live token.
  module JobFinalization
    module_function

    def request!(session, summary:)
      run = session.run
      run.with_lock do
        session.reload
        raise ArgumentError, "authenticated live run session required" unless session.live?
        return if session.finalization_requested_at
        raise ArgumentError, "run has no managed worktree" unless run.managed_worktree?

        validate!(run)
        run.checkpoints.create!(run_session: session, outcome: "done", summary:)
        session.update!(outcome: "done", status: "done", result: summary, finalization_requested_at: Time.current)
        run.update!(status: "awaiting_review") if run.active?
      end
    end

    def validate!(run)
      Runner.for(run.workspace).verify_job_finished!(
        repository_path: WorktreeJanitor.repository_for(run), path: run.target_root,
        branch: run.branch_name, base_branch: run.base_branch
      )
    end

    def response_closed!(session_id)
      session = RunSession.find(session_id)
      return unless session.finalization_requested_at && !session.finalization_completed_at

      session.update!(finalization_ready_at: Time.current) unless session.finalization_ready_at
      # Let the CLI consume the delivered acknowledgment before killing it.
      JobFinalizationJob.set(wait: 5.seconds).perform_later(session.id)
    end

    # The recurring reconciler repairs a lost enqueue or an exhausted retry.
    def recover
      RunSession.where.not(finalization_ready_at: nil).where(finalization_completed_at: nil)
        .where(finalization_ready_at: ..5.seconds.ago).find_each do |session|
        JobFinalizationJob.perform_later(session.id)
      end
    end
  end
end

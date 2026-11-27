module Orchestrator
  # The operator taking a queued run out of the queue before it starts: most
  # often one blocked for good on a dependency that failed or was stopped
  # (RunDependencies), which otherwise sits there forever. close_session needs
  # a live session, and update_run_dependencies would release the run, which
  # starts it.
  #
  # The run becomes `stopped`, with stop_reason saying so (a queued run has no
  # session to record a checkpoint for), and keeps everything else: a run
  # queued after it then shows as blocked, and reopen_session can queue it
  # again.
  #
  # Only a queued run with no live session: anything that has launched is the
  # session's to end, through close_session. The change is a compare-and-set
  # on status "queued", the same condition RunDispatchJob claims a run with,
  # so when both race exactly one of them wins: the run is either launched or
  # stopped, never both.
  module RunCancel
    class NotCancellable < StandardError; end

    REASON = "Cancelled by the operator before it started."

    module_function

    def call(run)
      check!(run)
      cancelled = Run.where(id: run.id, status: "queued").where.not(id: RunSession.live.select(:run_id))
        .update_all(status: "stopped", stopped_at: Time.current, stop_reason: REASON, updated_at: Time.current)
      run.reload
      if cancelled != 1
        # Something got there first, most likely the dispatcher claiming it.
        check!(run)
        raise NotCancellable, "Run #{run.run_id} changed while it was being cancelled; look at it again."
      end
      run
    end

    # Raises NotCancellable with what to do instead.
    def check!(run)
      if run.live_session
        raise NotCancellable, "Run #{run.run_id} has a live session; end it with close_session instead."
      end

      case run.status
      when "queued" then nil
      when "launching", "running", "awaiting_review"
        raise NotCancellable, "Run #{run.run_id} is #{run.status.tr('_', ' ')}, not queued; only a queued run can be " \
          "cancelled. End its session with close_session#{' once it is up' if run.status == 'launching'}."
      else
        raise NotCancellable, "Run #{run.run_id} is already #{run.status}; there is nothing to cancel."
      end
    end
  end
end

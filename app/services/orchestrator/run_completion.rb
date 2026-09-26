module Orchestrator
  # What happens to a run once its session is genuinely over: the operator
  # closed it, or RunSessionReconcileJob noticed the process died. Single place
  # so those paths can never disagree about a run's terminal state or about
  # releasing its concurrency slot.
  #
  # A session merely going idle does NOT come through here -- see
  # RunIdleReport. Nothing in this module publishes: opening a pull request is
  # the operator's decision, taken from the run screen after reading the pane,
  # not something a finished session triggers on its way out.
  module RunCompletion
    module_function

    def call(run:, outcome:, summary: nil)
      run.with_lock do
        case outcome
        when "done"
          # Non-terminal on purpose: the work may be worth publishing and only
          # the operator decides that, so the run waits for them rather than
          # being closed out or pushed to GitHub automatically.
          run.update!(status: "awaiting_review")
        when "blocked"
          run.update!(status: "stopped", stopped_at: Time.current)
        when "failed"
          run.update!(status: "failed", stopped_at: Time.current)
        else
          raise ArgumentError, "unknown run outcome: #{outcome.inspect}"
        end
      end

      BusEvent.publish("run.finished", run_id: run.run_id, payload: {
        runId: run.run_id, outcome:, summary:
      })
      # The slot this run was holding is free now, so the next queued run can
      # start without waiting for the dispatcher's own interval to come round.
      RunDispatchJob.perform_later
      run
    end
  end
end

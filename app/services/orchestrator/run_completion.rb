module Orchestrator
  # What happens to a run once its session is over, whatever ended it: the
  # agent's own run_done call, or RunSessionReconcileJob noticing the process
  # died. Single place so those two paths can never disagree about a run's
  # terminal state or about releasing its concurrency slot.
  module RunCompletion
    module_function

    def call(run:, outcome:, summary: nil)
      run.with_lock do
        case outcome
        when "done"
          # The run stays non-terminal through publication: pushing the branch
          # and opening the PR can fail, and a run that failed to publish is
          # not a completed run. PublishRunJob owns the final status.
          run.update!(publication_status: "publishing")
          PublishRunJob.perform_later(run.id)
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

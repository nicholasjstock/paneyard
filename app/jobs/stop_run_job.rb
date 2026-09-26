# Stops a run on the operator's say-so: kills its session's process, closes
# the herdr workspace, and releases the concurrency slot so the next queued
# run can start.
#
# The worktree is deliberately left in place -- a stopped run's work is often
# still wanted, and reclaiming it is WorktreeJanitor's job once it has been
# terminal long enough (and never while it is dirty).
class StopRunJob < ApplicationJob
  queue_as :default

  def perform(id)
    run = Run.find(id)
    session = run.live_session

    if session
      Orchestrator::RunSessionRunner.finish!(session, outcome: "failed", result: "Stopped by the operator.")
    end

    run.update!(status: "stopped", stopped_at: Time.current)
    RunDispatchJob.perform_later
  end
end

# Provisions a claimed run's worktree and opens its interactive session in
# it, both in RunSessionRunner.start! (herdr makes the worktree and opens it as
# the session's workspace in one call).
#
# Split out of RunDispatchJob because it is slow and failure-prone (git, the
# herdr socket, a CLI's startup), and because a failure here must free the
# slot rather than wedge the dispatcher.
class StartRunSessionJob < ApplicationJob
  queue_as :default

  def perform(id)
    run = Run.find(id)
    return unless run.status == "launching"

    Orchestrator::RunSessionRunner.start!(run)
    run.update!(status: "running", started_at: Time.current)
  rescue => error
    # Whatever went wrong -- a missing base branch, herdr not running, a CLI
    # that never became ready -- the run is done and its slot must go back.
    run&.update(status: "failed", stopped_at: Time.current, launch_error: error.message)
    RunDispatchJob.perform_later
    raise
  end
end

# Provisions a claimed run's worktree and opens its interactive session.
#
# Split out of RunDispatchJob because both halves are slow and failure-prone
# in different ways (git on one side, the herdr socket and a CLI's startup on
# the other), and because a failure here must free the slot rather than wedge
# the dispatcher.
class StartRunSessionJob < ApplicationJob
  queue_as :default

  def perform(id)
    run = Run.find(id)
    return unless run.status == "launching"

    Orchestrator::GitWorktree.provision!(run)
    Orchestrator::RunSessionRunner.start!(run)
    run.update!(status: "running", started_at: Time.current)
  rescue => error
    # Whatever went wrong -- a dirty source checkout, herdr not running, a CLI
    # that never became ready -- the run is done and its slot must go back.
    run&.update(status: "failed", stopped_at: Time.current,
      publication_status: "failed", publication_error: error.message)
    RunDispatchJob.perform_later
    raise
  end
end

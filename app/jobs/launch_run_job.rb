# Starts a brand-new orchestrator run: seeds the initial planner request
# on the bus and marks the run running. TickRunJob (a recurring job, see
# config/recurring.yml) picks it up from there -- no separate OS process
# to spawn/track anymore (contrast with the old bin/supervisor_launcher*
# tick loop this replaced, whose PID used to be recorded on
# Run#supervisor_pid).
#
# Runs via ActiveJob (not inline in the controller) so the web request
# stays fast and a failure is visible/retryable like any other job.
class LaunchRunJob < ApplicationJob
  queue_as :default

  def perform(id)
    run = Run.find(id)

    run.spawn_requests.create!(
      asked_by: run.launched_by.presence || "ops_hub",
      scope: "workflow-plan.md",
      text: run.task,
      requested_role: "planner",
      priority: "blocking",
      tags: %w[ops-hub launch]
    )

    run.update!(status: "running", started_at: Time.current)
  rescue => e
    run&.update!(status: "failed")
    raise
  end
end

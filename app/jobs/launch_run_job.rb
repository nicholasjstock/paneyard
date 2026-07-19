# Starts a brand-new orchestrator run: seeds the initial planning request
# on the bus and marks the run running. TickRunJob claims that request and
# queues one bounded PlannerDecisionJob; planning is Rails-owned and does
# not spawn a stateful planner process.
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

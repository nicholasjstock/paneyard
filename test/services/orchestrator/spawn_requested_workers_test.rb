require "test_helper"

class Orchestrator::SpawnRequestedWorkersTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "queues a Rails planner decision instead of spawning a planner process" do
    workspace = Workspace.create!(name: "spawn-planner-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s)
    run = workspace.runs.create!(
      run_id: "spawn-planner-#{SecureRandom.hex(4)}", task: "Plan the run",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    request = run.spawn_requests.create!(
      asked_by: "worker", scope: "workflow-plan.md", text: "Choose the next step.",
      requested_role: "planner", priority: "blocking"
    )

    assert_enqueued_with(job: PlannerDecisionJob) do
      spawned = Orchestrator::SpawnRequestedWorkers.call(run:)
      assert_empty spawned
    end

    assert_equal "fulfilled", request.reload.status
    assert_equal "planner_decision_job", request.fulfilled_by
    assert_equal "queued", run.planner_decisions.find_by!(spawn_request_id: request.request_id).status
    assert_empty run.workers.where(role: "planner")
  end
end

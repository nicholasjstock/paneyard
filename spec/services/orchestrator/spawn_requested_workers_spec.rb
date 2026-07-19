require "rails_helper"

RSpec.describe Orchestrator::SpawnRequestedWorkers do
  include ActiveJob::TestHelper

  it "queues a Rails planner decision instead of spawning a planner process" do
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

  it "spawns a chaperone worker with a reissued capability against the matching pending review" do
    workspace = Workspace.create!(name: "spawn-chaperone-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "spawn-chaperone-#{SecureRandom.hex(4)}", task: "Review a repeated failure",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    review, original_token = ChaperoneReview.issue!(
      run:, lineage_key: "diagnosis-lineage", step_attempt_ids: [], summary: "Repeated blocked diagnosis."
    )
    request = run.spawn_requests.create!(
      asked_by: "chaperone", scope: review.lineage_key, lineage_key: review.lineage_key,
      text: "Repeated blocked diagnosis.", requested_role: "chaperone", priority: "blocking", model_tier: "strong"
    )

    spawned = nil
    expect(Orchestrator::WorkerSpawner).to receive(:spawn_worker) do |**kwargs|
      spawned = kwargs
      instance_double(Worker, worker_id: kwargs[:worker_id])
    end

    Orchestrator::SpawnRequestedWorkers.call(run:)

    assert_equal "chaperone", spawned[:role]
    assert_equal "strong", spawned[:model_tier]
    assert_equal review.lineage_key, spawned[:scope]
    expect(spawned[:mcp_override][:token]).not_to eq(original_token)
    expect(ChaperoneReview.authenticate(spawned[:mcp_override][:token])).to eq(review)
    expect(spawned[:mcp_override][:allowed_tools]).to eq(Orchestrator::ChaperoneMcpServer::TOOL_NAMES)
    assert_equal "fulfilled", request.reload.status
  end

  it "dismisses a chaperone spawn request when no matching pending review is found" do
    workspace = Workspace.create!(name: "spawn-chaperone-missing-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "spawn-chaperone-missing-#{SecureRandom.hex(4)}", task: "Review a repeated failure",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    request = run.spawn_requests.create!(
      asked_by: "chaperone", scope: "stale-lineage", lineage_key: "stale-lineage",
      text: "Repeated blocked diagnosis.", requested_role: "chaperone", priority: "blocking", model_tier: "strong"
    )

    expect(Orchestrator::WorkerSpawner).not_to receive(:spawn_worker)

    spawned = Orchestrator::SpawnRequestedWorkers.call(run:)

    assert_empty spawned
    assert_equal "dismissed", request.reload.status
  end
end

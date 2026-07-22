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

  it "spawns a verifier worker through the generic dispatch path with a read-only, source-protected sandbox" do
    workspace = Workspace.create!(name: "spawn-verifier-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "spawn-verifier-#{SecureRandom.hex(4)}", task: "Verify a claim",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    request = run.spawn_requests.create!(
      asked_by: "planner", scope: "acceptance-verify-outcome", lineage_key: "acceptance:outcome",
      text: "Independently verify the claim.", requested_role: "verifier", priority: "blocking",
      model_tier: "small", execution_mode: "verification", write_scope: "source_protected", allowed_paths: []
    )

    spawned = nil
    expect(Orchestrator::WorkerSpawner).to receive(:spawn_worker) do |**kwargs|
      spawned = kwargs
      instance_double(Worker, worker_id: kwargs[:worker_id])
    end

    Orchestrator::SpawnRequestedWorkers.call(run:)

    assert_equal "verifier", spawned[:role]
    assert_equal "source_protected", spawned[:write_scope]
    assert_equal [], spawned[:allowed_paths]
    assert_equal "verification", spawned[:mode]
    assert_equal "small", spawned[:model_tier]
    assert_equal "fulfilled", request.reload.status
  end

  it "adds project-init-discovered test directories to implementation worker authority" do
    project_root = Dir.mktmpdir
    source_root = File.join(project_root, "main")
    FileUtils.mkdir_p(File.join(source_root, "quality", "checks"))
    workspace = Workspace.create!(
      name: "spawn-test-roots-#{SecureRandom.hex(4)}", root_path: project_root,
      test_path_patterns: [ "quality/checks" ]
    )
    run = workspace.runs.create!(
      run_id: "spawn-test-roots-#{SecureRandom.hex(4)}", task: "Implement with tests", target_root: source_root,
      launcher_variant: "claude", status: "running"
    )
    run.spawn_requests.create!(
      asked_by: "planner", scope: "fix.md", text: "Implement the fix.", requested_role: "worker", priority: "blocking",
      execution_mode: "implementation", write_scope: "scoped_changes", allowed_paths: [ "app/example.rb" ]
    )

    spawned = nil
    expect(Orchestrator::WorkerSpawner).to receive(:spawn_worker) do |**kwargs|
      spawned = kwargs
      instance_double(Worker, worker_id: kwargs[:worker_id])
    end

    Orchestrator::SpawnRequestedWorkers.call(run:)

    expect(spawned[:allowed_paths]).to contain_exactly("app/example.rb", "quality/checks")
  ensure
    FileUtils.remove_entry(project_root) if project_root && Dir.exist?(project_root)
  end

  it "dispatches only one queued verifier per run, leaving later work queued" do
    workspace = Workspace.create!(name: "serial-verifiers-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "serial-verifiers-#{SecureRandom.hex(4)}", task: "Verify several claims",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    first = run.spawn_requests.create!(
      asked_by: "planner", scope: "acceptance-verify-first", lineage_key: "acceptance:first",
      text: "Verify the first claim.", requested_role: "verifier", priority: "blocking",
      model_tier: "small", execution_mode: "verification", write_scope: "source_protected", allowed_paths: []
    )
    second = run.spawn_requests.create!(
      asked_by: "planner", scope: "acceptance-verify-second", lineage_key: "acceptance:second",
      text: "Verify the second claim.", requested_role: "verifier", priority: "blocking",
      model_tier: "small", execution_mode: "verification", write_scope: "source_protected", allowed_paths: []
    )

    expect(Orchestrator::WorkerSpawner).to receive(:spawn_worker).once.and_return(instance_double(Worker))

    Orchestrator::SpawnRequestedWorkers.call(run:)

    assert_equal "fulfilled", first.reload.status
    assert_equal "open", second.reload.status
  end

  it "does not dispatch a worker while a Rails planner decision is in flight" do
    workspace = Workspace.create!(name: "serial-planner-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "serial-planner-#{SecureRandom.hex(4)}", task: "Plan before verifying",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    planner_request = run.spawn_requests.create!(
      asked_by: "worker", scope: "workflow-plan.md", text: "Choose the next step.",
      requested_role: "planner", priority: "blocking"
    )
    PlannerDecision.create!(run:, spawn_request: planner_request, status: "running")
    verifier_request = run.spawn_requests.create!(
      asked_by: "planner", scope: "acceptance-verify-outcome", lineage_key: "acceptance:outcome",
      text: "Verify the claim.", requested_role: "verifier", priority: "blocking",
      model_tier: "small", execution_mode: "verification", write_scope: "source_protected", allowed_paths: []
    )

    expect(Orchestrator::WorkerSpawner).not_to receive(:spawn_worker)

    assert_empty Orchestrator::SpawnRequestedWorkers.call(run:)
    assert_equal "open", verifier_request.reload.status
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

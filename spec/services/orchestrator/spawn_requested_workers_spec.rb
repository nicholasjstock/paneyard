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
    assert_equal "high", spawned[:effort]
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

  it "grants the complete project-init-protected source surface to implementation workers" do
    project_root = Dir.mktmpdir
    source_root = File.join(project_root, "main")
    workspace = Workspace.create!(
      name: "spawn-test-roots-#{SecureRandom.hex(4)}", root_path: project_root,
      protected_path_patterns: [ "app/**", "quality/checks/**" ]
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

    expect(spawned[:allowed_paths]).to contain_exactly("app/**", "quality/checks/**")
  ensure
    FileUtils.remove_entry(project_root) if project_root && Dir.exist?(project_root)
  end

  it "grants the complete project-init-protected source surface to a finalization seeder" do
    project_root = Dir.mktmpdir
    source_root = File.join(project_root, "main")
    workspace = Workspace.create!(
      name: "spawn-seeder-roots-#{SecureRandom.hex(4)}", root_path: project_root,
      protected_path_patterns: [ "app/**", "db/seeds.rb" ]
    )
    run = workspace.runs.create!(
      run_id: "spawn-seeder-roots-#{SecureRandom.hex(4)}", task: "Seed demo data", target_root: source_root,
      launcher_variant: "claude", status: "running"
    )
    run.spawn_requests.create!(
      asked_by: "orchestrator", scope: "seed-data.md", text: "Seed the workspace.", requested_role: "seeder", priority: "blocking",
      execution_mode: "implementation", write_scope: "scoped_changes"
    )

    spawned = nil
    expect(Orchestrator::WorkerSpawner).to receive(:spawn_worker) do |**kwargs|
      spawned = kwargs
      instance_double(Worker, worker_id: kwargs[:worker_id])
    end

    Orchestrator::SpawnRequestedWorkers.call(run:)

    expect(spawned[:role]).to eq("seeder")
    expect(spawned[:allowed_paths]).to contain_exactly("app/**", "db/seeds.rb")
  ensure
    FileUtils.remove_entry(project_root) if project_root && Dir.exist?(project_root)
  end

  it "grants the protected source surface to scoped infrastructure workers" do
    project_root = Dir.mktmpdir
    source_root = File.join(project_root, "main")
    FileUtils.mkdir_p(File.join(source_root, "app"))
    workspace = Workspace.create!(
      name: "spawn-infrastructure-roots-#{SecureRandom.hex(4)}", root_path: project_root,
      protected_path_patterns: [ "app/**" ]
    )
    run = workspace.runs.create!(
      run_id: "spawn-infrastructure-roots-#{SecureRandom.hex(4)}", task: "Repair setup", target_root: source_root,
      launcher_variant: "codex", status: "running"
    )
    run.spawn_requests.create!(
      asked_by: "planner", scope: "repair.md", text: "Repair the environment.", requested_role: "infrastructure", priority: "blocking",
      execution_mode: "infrastructure", write_scope: "scoped_changes", allowed_paths: []
    )

    spawned = nil
    expect(Orchestrator::WorkerSpawner).to receive(:spawn_worker) do |**kwargs|
      spawned = kwargs
      instance_double(Worker, worker_id: kwargs[:worker_id])
    end

    Orchestrator::SpawnRequestedWorkers.call(run:)

    expect(spawned[:allowed_paths]).to eq([ "app/**" ])
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

    expect(Orchestrator::WorkerSpawner).to receive(:spawn_worker).once.and_return(instance_double(Worker, worker_id: "test-worker-id"))

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

  it "dismisses a worker spawn request when required artifacts do not exist" do
    workspace = Workspace.create!(name: "spawn-missing-artifacts-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "spawn-missing-artifacts-#{SecureRandom.hex(4)}", task: "Check artifact validation",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    request = run.spawn_requests.create!(
      asked_by: "planner", scope: "next-worker.md", text: "Do work.",
      requested_role: "worker", priority: "blocking", required_artifacts: [ "diagnosis.md", "evidence.json" ]
    )

    expect(Orchestrator::WorkerSpawner).not_to receive(:spawn_worker)

    spawned = Orchestrator::SpawnRequestedWorkers.call(run:)

    assert_empty spawned
    assert_equal "dismissed", request.reload.status
    assert_match(/Required artifacts not found/, request.reload.dismissal_note)
  end

  it "spawns a worker when all required artifacts exist" do
    project_root = Dir.mktmpdir
    artifact_dir = File.join(project_root, ".workflow-orchestrator", "artifacts", "test-run")
    FileUtils.mkdir_p(artifact_dir)
    File.write(File.join(artifact_dir, "diagnosis.md"), "# Diagnosis\nFound the issue.")
    File.write(File.join(artifact_dir, "evidence.json"), '{"key": "value"}')

    workspace = Workspace.create!(name: "spawn-with-artifacts-#{SecureRandom.hex(4)}", root_path: project_root)
    run = workspace.runs.create!(
      run_id: "test-run", task: "Work with artifacts",
      target_root: project_root, launcher_variant: "claude", status: "running"
    )
    request = run.spawn_requests.create!(
      asked_by: "planner", scope: "next-worker.md", text: "Review the artifacts.",
      requested_role: "worker", priority: "blocking",
      required_artifacts: [ "diagnosis.md", "evidence.json" ]
    )

    spawned = nil
    expect(Orchestrator::WorkerSpawner).to receive(:spawn_worker) do |**kwargs|
      spawned = kwargs
      instance_double(Worker, worker_id: kwargs[:worker_id])
    end

    Orchestrator::SpawnRequestedWorkers.call(run:)

    assert_equal "fulfilled", request.reload.status
    assert_not_nil spawned
  ensure
    FileUtils.remove_entry(project_root) if project_root && Dir.exist?(project_root)
  end

  it "includes inherited artifact metadata in the worker prompt" do
    project_root = Dir.mktmpdir
    artifact_dir = File.join(project_root, ".workflow-orchestrator", "artifacts", "test-run-2")
    FileUtils.mkdir_p(artifact_dir)
    File.write(File.join(artifact_dir, "diagnosis.md"), "# Diagnosis\nAnalysis of the issue.")
    File.write(File.join(artifact_dir, "trace.log"), "Line 1\nLine 2\nLine 3")

    workspace = Workspace.create!(name: "spawn-artifact-prompt-#{SecureRandom.hex(4)}", root_path: project_root)
    run = workspace.runs.create!(
      run_id: "test-run-2", task: "Check prompt generation",
      target_root: project_root, launcher_variant: "claude", status: "running"
    )
    request = run.spawn_requests.create!(
      asked_by: "planner", scope: "next-worker.md", text: "Review the prior work.",
      requested_role: "worker", priority: "blocking",
      inherited_artifacts: [ "diagnosis.md", "trace.log" ]
    )

    spawned = nil
    expect(Orchestrator::WorkerSpawner).to receive(:spawn_worker) do |**kwargs|
      spawned = kwargs
      instance_double(Worker, worker_id: kwargs[:worker_id])
    end

    Orchestrator::SpawnRequestedWorkers.call(run:)

    assert_equal "fulfilled", request.reload.status
    assert_not_nil spawned
    prompt = spawned[:prompt]
    assert_includes prompt, "## Inherited Artifacts"
    assert_includes prompt, "diagnosis.md"
    assert_includes prompt, "trace.log"
    assert_includes prompt, "Use `read_workflow_artifact` to read these files"
  ensure
    FileUtils.remove_entry(project_root) if project_root && Dir.exist?(project_root)
  end

  it "passes inherited_artifacts parameter to spawn_worker" do
    project_root = Dir.mktmpdir
    artifact_dir = File.join(project_root, ".workflow-orchestrator", "artifacts", "test-run-3")
    FileUtils.mkdir_p(artifact_dir)
    File.write(File.join(artifact_dir, "diagnosis.md"), "# Diagnosis")

    workspace = Workspace.create!(name: "spawn-worker-artifacts-#{SecureRandom.hex(4)}", root_path: project_root)
    run = workspace.runs.create!(
      run_id: "test-run-3", task: "Check inherited_artifacts parameter",
      target_root: project_root, launcher_variant: "claude", status: "running"
    )
    request = run.spawn_requests.create!(
      asked_by: "planner", scope: "next-worker.md", text: "Do work.",
      requested_role: "worker", priority: "blocking",
      inherited_artifacts: [ "diagnosis.md" ]
    )

    spawned = nil
    expect(Orchestrator::WorkerSpawner).to receive(:spawn_worker) do |**kwargs|
      spawned = kwargs
      instance_double(Worker, worker_id: kwargs[:worker_id])
    end

    Orchestrator::SpawnRequestedWorkers.call(run:)

    assert_equal "fulfilled", request.reload.status
    assert_equal [ "diagnosis.md" ], spawned[:inherited_artifacts]
  ensure
    FileUtils.remove_entry(project_root) if project_root && Dir.exist?(project_root)
  end
end

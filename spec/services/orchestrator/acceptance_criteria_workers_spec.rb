require "rails_helper"

RSpec.describe Orchestrator::AcceptanceCriteriaWorkers do
  it "groups a worker's activity under the acceptance criterion its assignment addresses" do
    run = build_run
    criterion = run.acceptance_criteria.create!(key: "demo-perf-baseline", content: "Baseline measured", status: "in_progress")
    request = run.spawn_requests.create!(
      asked_by: "planner", scope: "measure.md", text: "Measure the baseline.",
      requested_role: "worker", priority: "blocking", status: "fulfilled",
      fulfilled_worker_id: SecureRandom.uuid, lineage_key: "measure-demo-performance"
    )
    worker = create_worker(run, request, "measure-worker")
    request.update!(fulfilled_worker_id: worker.worker_id)
    criterion.fulfillment_steps.create!(run_id: run.run_id, lineage_key: request.lineage_key)

    activities = Orchestrator::WorkerActivity.for_workers([ worker ])
    groups = described_class.group(run_id: run.run_id, activities: activities)

    assert_equal [ worker.worker_id ], groups[criterion.id].map { |activity| activity[:worker].worker_id }
    assert_empty groups[Orchestrator::AcceptanceCriteriaWorkers::UNASSIGNED]
  end

  it "buckets a worker with no criterion-linked lineage_key as unassigned" do
    run = build_run
    request = run.spawn_requests.create!(
      asked_by: "worker", scope: "workflow-plan.md", text: "Choose the next step.",
      requested_role: "planner", priority: "blocking", status: "fulfilled",
      fulfilled_worker_id: SecureRandom.uuid
    )
    worker = create_worker(run, request, "planner-main", role: "planner")
    request.update!(fulfilled_worker_id: worker.worker_id)

    activities = Orchestrator::WorkerActivity.for_workers([ worker ])
    groups = described_class.group(run_id: run.run_id, activities: activities)

    assert_equal [ worker.worker_id ], groups[Orchestrator::AcceptanceCriteriaWorkers::UNASSIGNED].map { |activity| activity[:worker].worker_id }
  end

  it "puts a worker under every criterion its lineage_key addresses" do
    run = build_run
    criterion_a = run.acceptance_criteria.create!(key: "criterion-a", content: "A", status: "in_progress")
    criterion_b = run.acceptance_criteria.create!(key: "criterion-b", content: "B", status: "in_progress")
    request = run.spawn_requests.create!(
      asked_by: "planner", scope: "verify.md", text: "Verify both.",
      requested_role: "worker", priority: "blocking", status: "fulfilled",
      fulfilled_worker_id: SecureRandom.uuid, lineage_key: "verify-both"
    )
    worker = create_worker(run, request, "verify-worker")
    request.update!(fulfilled_worker_id: worker.worker_id)
    criterion_a.fulfillment_steps.create!(run_id: run.run_id, lineage_key: request.lineage_key)
    criterion_b.fulfillment_steps.create!(run_id: run.run_id, lineage_key: request.lineage_key)

    activities = Orchestrator::WorkerActivity.for_workers([ worker ])
    groups = described_class.group(run_id: run.run_id, activities: activities)

    assert_equal [ worker.worker_id ], groups[criterion_a.id].map { |activity| activity[:worker].worker_id }
    assert_equal [ worker.worker_id ], groups[criterion_b.id].map { |activity| activity[:worker].worker_id }
  end

  private

  def create_worker(run, request, nickname, role: "worker")
    run.workers.create!(
      worker_id: SecureRandom.uuid, role: role, nickname: nickname, reason: request.text,
      scope: request.scope, status: "running", pid: 20_000, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/#{nickname}.prompt").to_s, log_path: Rails.root.join("tmp/#{nickname}.log").to_s,
      last_message_path: Rails.root.join("tmp/#{nickname}.last").to_s, env_path: Rails.root.join("tmp/#{nickname}.env").to_s,
      model: "haiku"
    )
  end

  def build_run
    root = Dir.mktmpdir("acceptance-criteria-workers")
    workspace = Workspace.create!(name: "criteria-workers-#{SecureRandom.hex(4)}", root_path: root)
    workspace.runs.create!(run_id: "criteria-workers-#{SecureRandom.hex(4)}", task: "Fix admin flow", target_root: root, launcher_variant: "claude", status: "running")
  end
end

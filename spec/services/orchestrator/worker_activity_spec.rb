require "rails_helper"

RSpec.describe Orchestrator::WorkerActivity do
  def create_worker(status: "running", stop_reason: nil)
    workspace = Workspace.create!(name: "worker-activity-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(
      run_id: "demo-worker-activity-#{SecureRandom.hex(4)}",
      task: "Inspect worker activity",
      workspace: workspace,
      target_root: workspace.root_path,
      launcher_variant: "claude",
      status: "running"
    )
    workers_dir = File.join(workspace.root_path, "workers")
    FileUtils.mkdir_p(workers_dir)

    run.workers.create!(
      worker_id: SecureRandom.uuid,
      role: "worker",
      nickname: "worker-main",
      reason: "Inspect the current state.",
      scope: "fix-summary.md",
      status: status,
      pid: 123_456,
      prompt_path: File.join(workers_dir, "worker-main.prompt.txt"),
      log_path: File.join(workers_dir, "worker-main.log"),
      last_message_path: File.join(workers_dir, "worker-main.last-message.txt"),
      env_path: File.join(workers_dir, "worker-main.env.json"),
      command: "claude",
      args: [],
      stopped_at: status == "stopped" ? Time.current : nil,
      stop_reason: stop_reason
    )
  end

  it "shows the full worker log and reports its activity time" do
    worker = create_worker
    File.write(worker.log_path, "first log line\nsecond log line\n")
    File.write(worker.last_message_path, "Investigating the failing request.\n")

    activity = described_class.for_workers([ worker ]).first

    expect(activity[:display_status]).to eq("running")
    expect(activity[:output_source]).to eq("Full worker log")
    expect(activity[:output_preview]).to include("first log line")
    expect(activity[:output_preview]).to include("second log line")
    expect(activity[:output_preview]).to include("Investigating the failing request.")
    expect(activity[:last_activity_at]).to be_within(2.seconds).of(File.mtime(worker.last_message_path))
  end

  it "keeps the complete log and flags an unexpected stop" do
    worker = create_worker(status: "stopped", stop_reason: "Process no longer running after reconciliation.")
    File.write(worker.log_path, (1..10).map { |number| "line #{number}" }.join("\n"))

    activity = described_class.for_workers([ worker ]).first

    expect(activity[:display_status]).to eq("attention")
    expect(activity[:status_label]).to eq("needs attention")
    expect(activity[:output_source]).to eq("Full worker log")
    expect(activity[:output_preview]).to include("line 10")
    expect(activity[:output_preview]).to include("line 1")
  end

  it "surfaces the fulfilling spawn request's instructions as the assignment" do
    worker = create_worker
    worker.run.spawn_requests.create!(
      asked_by: "planner", scope: worker.scope, requested_role: worker.role, priority: "blocking",
      text: "Run the failing scenario and capture a real timing measurement.",
      context: "Previous attempt only produced a code-inspection estimate.",
      fulfilled_worker_id: worker.worker_id
    )

    activity = described_class.for_workers([ worker ]).first

    expect(activity[:assignment_text]).to eq("Run the failing scenario and capture a real timing measurement.")
    expect(activity[:assignment_context]).to eq("Previous attempt only produced a code-inspection estimate.")
  end

  it "leaves the assignment blank when no spawn request fulfilled this worker" do
    worker = create_worker

    activity = described_class.for_workers([ worker ]).first

    expect(activity[:assignment_text]).to be_nil
  end

  it "prioritizes active workers, then attention-needed workers, before stopped history" do
    running = create_worker
    attention = create_worker(status: "stopped", stop_reason: "Process no longer running.")
    stopped = create_worker(status: "stopped", stop_reason: "Manually stopped from ops hub")
    now = Time.current
    running.update_columns(started_at: now - 10.minutes)
    attention.update_columns(started_at: now - 1.minute, stopped_at: now - 30.seconds)
    stopped.update_columns(started_at: now - 20.minutes, stopped_at: now - 2.minutes)

    activities = described_class.for_workers([ stopped, attention, running ])

    expect(activities.map { |activity| activity[:worker] }).to eq([ running, attention, stopped ])
  end

  it "normalizes planner decisions into the worker activity entry shape" do
    worker = create_worker
    request = worker.run.spawn_requests.create!(
      asked_by: "operator", requested_role: "worker", scope: "next.md",
      text: "Choose the next step.", status: "fulfilled", priority: "blocking"
    )
    decision = worker.run.planner_decisions.create!(spawn_request: request, status: "completed")
    worker_activity = described_class.for_workers([ worker ])

    entries = described_class.for_planner_entries(worker_activity, [ decision ])

    expect(entries.map { |entry| entry[:entry_type] }).to eq([ :planner_decision, :worker ])
    expect(entries.first).to include(role: "planner", worker: nil, decision: decision, at: decision.created_at)
  end

  it "sorts planner decisions and planner activities by descending activity time" do
    worker = create_worker
    worker.update_columns(started_at: 10.minutes.ago)
    request = worker.run.spawn_requests.create!(
      asked_by: "operator", requested_role: "worker", scope: "next.md",
      text: "Choose the next step.", status: "fulfilled", priority: "blocking"
    )
    older_decision = worker.run.planner_decisions.create!(spawn_request: request, status: "completed", created_at: 5.minutes.ago)
    newer_request = worker.run.spawn_requests.create!(
      asked_by: "operator", requested_role: "worker", scope: "newer.md",
      text: "Choose the newer next step.", status: "fulfilled", priority: "blocking"
    )
    newer_decision = worker.run.planner_decisions.create!(spawn_request: newer_request, status: "completed", created_at: 1.minute.ago)

    entries = described_class.for_planner_entries(described_class.for_workers([ worker ]), [ older_decision, newer_decision ])

    expect(entries.map { |entry| entry[:entry_type] }).to eq([ :planner_decision, :planner_decision, :worker ])
    expect(entries.map { |entry| entry[:decision] }).to eq([ newer_decision, older_decision, nil ])
  end
end

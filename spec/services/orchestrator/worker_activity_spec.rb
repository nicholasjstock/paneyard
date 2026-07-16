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

  it "prefers the latest agent message and reports its activity time" do
    worker = create_worker
    File.write(worker.log_path, "older log line\n")
    File.write(worker.last_message_path, "Investigating the failing request.\n")

    activity = described_class.for_workers([ worker ]).first

    expect(activity[:display_status]).to eq("running")
    expect(activity[:output_source]).to eq("Latest agent message")
    expect(activity[:output_preview]).to eq("Investigating the failing request.\n")
    expect(activity[:last_activity_at]).to be_within(2.seconds).of(File.mtime(worker.last_message_path))
  end

  it "uses a bounded log tail and flags an unexpected stop" do
    worker = create_worker(status: "stopped", stop_reason: "Process no longer running after reconciliation.")
    File.write(worker.log_path, (1..10).map { |number| "line #{number}" }.join("\n"))

    activity = described_class.for_workers([ worker ]).first

    expect(activity[:display_status]).to eq("attention")
    expect(activity[:status_label]).to eq("needs attention")
    expect(activity[:output_source]).to eq("Latest log output")
    expect(activity[:output_preview]).to include("line 10")
    expect(activity[:output_preview]).not_to include("line 1\n")
  end

  it "sorts active workers before attention and quiet stopped history" do
    running = create_worker
    attention = create_worker(status: "stopped", stop_reason: "Process no longer running.")
    stopped = create_worker(status: "stopped", stop_reason: "Manually stopped from ops hub")

    activities = described_class.for_workers([ stopped, attention, running ])

    expect(activities.map { |activity| activity[:display_status] }).to eq(%w[running attention stopped])
  end
end

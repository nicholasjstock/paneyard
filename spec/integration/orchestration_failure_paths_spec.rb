require "rails_helper"

RSpec.describe "orchestration failure paths" do
  it "marks the run failed when launch setup raises" do
    run = create_run("launch-failure", status: "launching")

    allow_any_instance_of(Run).to receive(:update!).and_call_original
    allow_any_instance_of(Run).to receive(:update!)
      .with(hash_including(status: "running", started_at: kind_of(Time)))
      .and_raise(StandardError, "launch exploded")

    expect { LaunchRunJob.perform_now(run.id) }.to raise_error(StandardError, "launch exploded")

    expect(run.reload.status).to eq("failed")
    expect(run.spawn_requests.open_only.count).to eq(1)
  end

  it "leaves recovery alone while a worker is still active" do
    run = create_run("stalled-worker")
    create_running_worker(run: run, nickname: "planner-stalled", stale_seconds: 500)
    Orchestrator::TickState.write(
      run_id: run.run_id,
      phase: "planning",
      tick_count: 1,
      last_plan_summary: "Investigate the slow UI path.",
      pending_spawn_keys: [],
      following_steps: [ { owner: "worker", artifact: "fix-summary.md", success_check: "Ship the fix." } ],
      last_updated_at: Time.current.iso8601
    )

    TickRunJob.perform_now

    latest_tick = OrchestratorTick.for_run(run.run_id).last
    recovery_request = run.spawn_requests.where(asked_by: "planner", requested_role: "planner", scope: "workflow-plan.md")
      .order(:created_at).last

    expect(latest_tick.phase).to eq("planning")
    expect(latest_tick.last_stall_finding).to be_nil
    expect(recovery_request).to be_nil
  end

  it "does not spawn a recovery planner while active work and a blocking question exist" do
    run = create_run("blocked-on-user")
    create_running_worker(run: run, nickname: "planner-waiting", stale_seconds: 500)
    Orchestrator::TickState.write(
      run_id: run.run_id,
      phase: "planning",
      tick_count: 2,
      last_plan_summary: "Need a product decision.",
      pending_spawn_keys: [],
      following_steps: [],
      last_updated_at: Time.current.iso8601
    )
    run.user_questions.create!(
      asked_by: "planner",
      scope: "workflow-plan.md",
      text: "Should the old flow stay enabled?",
      priority: "blocking"
    )

    TickRunJob.perform_now

    latest_tick = OrchestratorTick.for_run(run.run_id).last

    expect(latest_tick.phase).to eq("planning")
    expect(run.spawn_requests.where(asked_by: "planner", requested_role: "planner", scope: "workflow-plan.md")).to be_empty
  end

  it "stops the run even if one worker refuses to shut down cleanly" do
    run = create_run("stop-failure")
    worker = create_running_worker(run: run, nickname: "planner-hard-stop", stale_seconds: 1)

    allow(Orchestrator::WorkerSpawner).to receive(:stop_worker).with(worker: worker, reason: "run stopped from ops hub")
      .and_raise(StandardError, "sigterm failed")

    expect { StopRunJob.perform_now(run.id) }.not_to raise_error

    expect(run.reload.status).to eq("stopped")
    expect(run.stopped_at).to be_present
    expect(worker.reload.status).to eq("running")
  end

  def create_run(suffix, status: "running")
    workspace_root = Dir.mktmpdir("workflow-#{suffix}")
    FileUtils.mkdir_p(File.join(workspace_root, "front", "demo-output", "agents-sdk", "workers"))
    workspace = Workspace.create!(name: "planner-#{suffix}-#{SecureRandom.hex(4)}", root_path: workspace_root)
    Run.create!(
      run_id: "demo-#{suffix}-#{SecureRandom.hex(4)}",
      task: "Exercise orchestration failure path #{suffix}",
      workspace: workspace,
      target_root: workspace.root_path,
      launcher_variant: "claude",
      status: status,
      launched_by: "operator",
      started_at: (Time.current if status == "running")
    )
  end

  def create_running_worker(run:, nickname:, stale_seconds:)
    workers_dir = File.join(run.target_root, "front", "demo-output", "agents-sdk", "workers")
    prompt_path = File.join(workers_dir, "#{nickname}.prompt.txt")
    log_path = File.join(workers_dir, "#{nickname}.log")
    last_message_path = File.join(workers_dir, "#{nickname}.last-message.txt")
    env_path = File.join(workers_dir, "#{nickname}.env.json")

    [ prompt_path, log_path, last_message_path, env_path ].each do |path|
      File.write(path, "#{nickname}\n")
    end

    stale_at = (Time.current - stale_seconds).to_time
    File.utime(stale_at, stale_at, prompt_path)
    File.utime(stale_at, stale_at, log_path)
    File.utime(stale_at, stale_at, last_message_path)

    run.workers.create!(
      worker_id: SecureRandom.uuid,
      role: "planner",
      nickname: nickname,
      reason: "Failure-path coverage",
      scope: "workflow-plan.md",
      status: "running",
      pid: 444_444,
      prompt_path: prompt_path,
      log_path: log_path,
      last_message_path: last_message_path,
      env_path: env_path,
      command: "claude",
      args: []
    )
  end
end

require "rails_helper"

RSpec.describe WorkerReconcileJob do
  it "classifies a Claude session-limit exit from the worker log" do
    workspace = Workspace.create!(name: "reconcile-test-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(
      workspace: workspace,
      run_id: "reconcile-test-#{SecureRandom.hex(4)}",
      task: "Test worker reconciliation",
      target_root: workspace.root_path,
      launcher_variant: "claude",
      status: "running"
    )
    log_path = File.join(workspace.root_path, "worker.log")
    File.write(log_path, <<~LOG)
      You've hit your session limit · resets 5pm (Europe/Paris)
      {"type":"result","model":"claude-haiku-4-5","num_turns":3,"total_cost_usd":0.1,"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40}}
    LOG
    worker = Worker.create!(
      worker_id: SecureRandom.uuid,
      run_id: run.run_id,
      role: "worker",
      nickname: "worker-test",
      reason: "Test worker",
      scope: "test.md",
      status: "running",
      pid: 999_999_999,
      prompt_path: log_path,
      log_path: log_path,
      last_message_path: log_path,
      env_path: log_path,
      command: "claude"
    )

    WorkerReconcileJob.perform_now

    assert_equal "stopped", worker.reload.status
    assert_equal "Claude session limit reached; worker exited before completing its handoff.", worker.stop_reason
    assert_equal "claude-haiku-4-5", worker.model
    assert_equal 3, worker.agent_turn_count
    assert_equal 30, worker.cache_read_input_tokens
    assert_includes worker.as_json[:outputTail], "session limit"
    assert_operator run.reload.capacity_available_at, :>, Time.current
    assert_equal "waiting_on_capacity", run.phase
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace&.root_path && File.exist?(workspace.root_path)
  end

  it "bounds stream-log diagnostics returned to planners" do
    directory = Dir.mktmpdir
    log_path = File.join(directory, "worker.log")
    File.write(log_path, "x" * 2_000)
    worker = Worker.allocate
    worker.define_singleton_method(:log_path) { log_path }

    assert_equal 1_203, worker.send(:output_tail).length
  ensure
    FileUtils.remove_entry(directory) if directory && File.exist?(directory)
  end

  it "does not report a failed handoff after a worker has completed one" do
    workspace = Workspace.create!(name: "reconcile-handoff-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(
      workspace: workspace,
      run_id: "reconcile-handoff-#{SecureRandom.hex(4)}",
      task: "Test completed handoff reconciliation",
      target_root: workspace.root_path,
      launcher_variant: "claude",
      status: "running"
    )
    log_path = File.join(workspace.root_path, "worker.log")
    File.write(log_path, "completed\n")
    worker = Worker.create!(
      worker_id: SecureRandom.uuid,
      run_id: run.run_id,
      role: "planner",
      nickname: "planner-test",
      reason: "Test planner",
      scope: "workflow-plan.md",
      status: "running",
      pid: 999_999_999,
      prompt_path: log_path,
      log_path: log_path,
      last_message_path: log_path,
      exit_status_path: log_path,
      env_path: log_path,
      command: "claude",
      handoff_completed_at: Time.current
    )

    WorkerReconcileJob.perform_now

    assert_equal "stopped", worker.reload.status
    assert_equal "Worker stopped after completing its handoff.", worker.stop_reason
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace&.root_path && File.exist?(workspace.root_path)
  end

  it "persists Claude's final response for the worker view" do
    workspace = Workspace.create!(name: "reconcile-final-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(
      workspace:, run_id: "reconcile-final-#{SecureRandom.hex(4)}", task: "Persist final response",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    log_path = File.join(workspace.root_path, "worker.log")
    last_message_path = File.join(workspace.root_path, "worker.last-message.txt")
    File.write(log_path, { type: "result", result: "The verification completed.", usage: {} }.to_json << "\n")
    worker = Worker.create!(
      worker_id: SecureRandom.uuid, run_id: run.run_id, role: "worker", nickname: "worker-final",
      reason: "Verify it.", scope: "verification.md", status: "running", pid: 999_999_999,
      prompt_path: log_path, log_path:, last_message_path:, env_path: log_path, command: "claude"
    )

    WorkerReconcileJob.perform_now

    expect(File.read(last_message_path)).to eq("The verification completed.\n")
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace&.root_path && File.exist?(workspace.root_path)
  end

  it "diagnostic worker payload excludes the launch prompt" do
    directory = Dir.mktmpdir
    log_path = File.join(directory, "worker.log")
    File.write(log_path, "worker output\n")
    worker = Worker.new(
      worker_id: "worker-id",
      run_id: "run-id",
      role: "worker",
      nickname: "worker",
      scope: "report.md",
      status: "stopped",
      started_at: Time.current,
      log_path: log_path,
      args: [ "very large prompt" ]
    )

    payload = worker.as_diagnostic_json

    assert_not payload.key?(:args)
    assert_not payload.key?(:promptPath)
  ensure
    FileUtils.remove_entry(directory) if directory && File.exist?(directory)
  end
end

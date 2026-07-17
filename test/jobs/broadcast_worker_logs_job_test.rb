require "test_helper"

class BroadcastWorkerLogsJobTest < ActiveSupport::TestCase
  test "records a changed active worker log" do
    workspace = Workspace.create!(name: "log-watch-test-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(
      workspace: workspace,
      run_id: "log-watch-test-#{SecureRandom.hex(4)}",
      task: "Test log broadcasts",
      target_root: workspace.root_path,
      launcher_variant: "claude",
      status: "running"
    )
    log_path = File.join(workspace.root_path, "worker.log")
    File.write(log_path, "stream event\n")
    worker = Worker.create!(
      worker_id: SecureRandom.uuid,
      run_id: run.run_id,
      role: "worker",
      nickname: "worker-test",
      reason: "Test worker",
      scope: "test.md",
      status: "running",
      pid: Process.pid,
      prompt_path: log_path,
      log_path: log_path,
      last_message_path: log_path,
      env_path: log_path,
      command: "claude"
    )

    BroadcastWorkerLogsJob.perform_now

    observed_at = worker.reload.log_updated_at
    assert_not_nil observed_at

    BroadcastWorkerLogsJob.perform_now

    assert_equal observed_at, worker.reload.log_updated_at
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace&.root_path && File.exist?(workspace.root_path)
  end
end

require "rails_helper"

RSpec.describe McpTools::StopRunCommandTool do
  it "stops a running command by signaling its process group, and is idempotent" do
    run, worker = create_run_and_worker
    command = Orchestrator::RunCommandRunner.start(
      run: run, requested_by_worker_id: worker.worker_id, executable: "/bin/sleep", arguments: [ "30" ]
    )

    first = described_class.call(runId: run.run_id, commandId: command.command_id, server_context: { worker_id: worker.worker_id })
    expect(first.structured_content[:status]).to eq("stopped")

    second = described_class.call(runId: run.run_id, commandId: command.command_id, server_context: { worker_id: worker.worker_id })
    expect(second.structured_content[:status]).to eq("stopped")
    expect(BusEvent.where(run_id: run.run_id, event_type: "command.stopped").count).to eq(1)
  end

  def create_run_and_worker
    root = Dir.mktmpdir("stop-run-command")
    workspace = Workspace.create!(name: "stop-run-command-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "stop-run-command-#{SecureRandom.hex(4)}", task: "Exercise stop_run_command",
      target_root: root, launcher_variant: "claude", status: "running"
    )
    worker = run.workers.create!(
      worker_id: SecureRandom.uuid, role: "worker", nickname: "worker-#{SecureRandom.hex(2)}", reason: "test",
      scope: "artifact.md", status: "running", pid: 99_999, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.prompt").to_s,
      log_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.log").to_s,
      last_message_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.last").to_s,
      env_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.env").to_s
    )
    [ run, worker ]
  end
end

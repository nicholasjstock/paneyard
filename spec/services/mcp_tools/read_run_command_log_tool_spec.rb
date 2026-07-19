require "rails_helper"

RSpec.describe McpTools::ReadRunCommandLogTool do
  it "returns a bounded window and the next cursor for a run command's log" do
    run, worker = create_run_and_worker
    command = run.run_commands.create!(executable: "/bin/echo", working_directory: run.target_root)
    log_path = File.join(Dir.mktmpdir("read-run-command-log"), "cmd.log")
    File.write(log_path, "0123456789")
    command.update!(log_path: log_path)

    response = described_class.call(
      runId: run.run_id, commandId: command.command_id, offset: 2, maxBytes: 3, server_context: { worker_id: worker.worker_id }
    )

    expect(response.structured_content[:text]).to eq("234")
    expect(response.structured_content[:nextCursor]).to eq(5)
    expect(response.structured_content[:hasMore]).to be(true)
  end

  it "rejects an unknown commandId" do
    run, worker = create_run_and_worker

    response = described_class.call(runId: run.run_id, commandId: "missing", server_context: { worker_id: worker.worker_id })

    expect(response.error?).to be(true)
  end

  def create_run_and_worker
    root = Dir.mktmpdir("read-run-command-log-tool")
    workspace = Workspace.create!(name: "read-run-command-log-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "read-run-command-log-#{SecureRandom.hex(4)}", task: "Exercise read_run_command_log",
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

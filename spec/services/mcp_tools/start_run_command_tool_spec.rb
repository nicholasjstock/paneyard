require "rails_helper"

RSpec.describe McpTools::StartRunCommandTool do
  it "starts a run-scoped command for the authenticated worker's own run" do
    run, worker = create_run_and_worker

    response = described_class.call(
      runId: run.run_id, executable: "/bin/echo", arguments: [ "hi" ], purpose: "smoke test",
      server_context: { worker_id: worker.worker_id }
    )

    expect(response.structured_content[:status]).to eq("running")
    expect(response.structured_content[:pid]).to be_present
    command = run.run_commands.find_by(command_id: response.structured_content[:commandId])
    expect(command.requested_by_worker_id).to eq(worker.worker_id)
  ensure
    run.run_commands.find_each { |c| Orchestrator::RunCommandRunner.stop(command: c, reason: "spec cleanup") }
  end

  it "rejects a worker whose capability belongs to a different run" do
    run, = create_run_and_worker
    _other_run, other_worker = create_run_and_worker

    response = described_class.call(
      runId: run.run_id, executable: "/bin/echo", server_context: { worker_id: other_worker.worker_id }
    )

    expect(response.error?).to be(true)
  end

  it "rejects an unauthenticated caller outside test-mode's server_context escape hatch" do
    run, = create_run_and_worker

    response = described_class.call(runId: run.run_id, executable: "/bin/echo", server_context: { worker_id: "unknown" })

    expect(response.error?).to be(true)
  end

  def create_run_and_worker
    root = Dir.mktmpdir("start-run-command")
    workspace = Workspace.create!(name: "start-run-command-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "start-run-command-#{SecureRandom.hex(4)}", task: "Exercise start_run_command",
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

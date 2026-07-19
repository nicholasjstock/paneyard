require "rails_helper"

RSpec.describe McpTools::GetRunCommandTool do
  it "returns reconciled status and rejects cross-run access" do
    run, worker = create_run_and_worker
    command = Orchestrator::RunCommandRunner.start(
      run: run, requested_by_worker_id: worker.worker_id, executable: "/bin/echo", arguments: [ "hi" ]
    )
    wait_until { Orchestrator::RunCommandRunner.reconcile!(command.reload).status == "exited" }

    response = described_class.call(runId: run.run_id, commandId: command.command_id, server_context: { worker_id: worker.worker_id })
    expect(response.structured_content[:status]).to eq("exited")
    expect(response.structured_content[:exitCode]).to eq(0)

    _other_run, other_worker = create_run_and_worker
    cross_run_response = described_class.call(
      runId: run.run_id, commandId: command.command_id, server_context: { worker_id: other_worker.worker_id }
    )
    expect(cross_run_response.error?).to be(true)
  end

  it "does not publish a duplicate command.exited event across repeated get calls" do
    run, worker = create_run_and_worker
    command = Orchestrator::RunCommandRunner.start(
      run: run, requested_by_worker_id: worker.worker_id, executable: "/bin/echo", arguments: [ "hi" ]
    )
    wait_until { Orchestrator::RunCommandRunner.reconcile!(command.reload).status == "exited" }

    2.times { described_class.call(runId: run.run_id, commandId: command.command_id, server_context: { worker_id: worker.worker_id }) }

    expect(BusEvent.where(run_id: run.run_id, event_type: "command.exited").count).to eq(1)
  end

  def create_run_and_worker
    root = Dir.mktmpdir("get-run-command")
    workspace = Workspace.create!(name: "get-run-command-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "get-run-command-#{SecureRandom.hex(4)}", task: "Exercise get_run_command",
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

  def wait_until(timeout: 5)
    deadline = Time.now + timeout
    loop do
      return true if yield
      raise "condition not met within #{timeout}s" if Time.now > deadline

      sleep 0.05
    end
  end
end

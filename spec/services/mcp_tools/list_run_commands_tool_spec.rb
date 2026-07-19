require "rails_helper"

RSpec.describe McpTools::ListRunCommandsTool do
  it "lists commands for the caller's own run, filterable by status" do
    run, worker = create_run_and_worker
    running = Orchestrator::RunCommandRunner.start(
      run: run, requested_by_worker_id: worker.worker_id, executable: "/bin/sleep", arguments: [ "30" ]
    )
    exited = Orchestrator::RunCommandRunner.start(
      run: run, requested_by_worker_id: worker.worker_id, executable: "/bin/echo", arguments: [ "hi" ]
    )
    wait_until { Orchestrator::RunCommandRunner.reconcile!(exited.reload).status == "exited" }

    all = described_class.call(runId: run.run_id, server_context: { worker_id: worker.worker_id })
    ids = all.structured_content[:commands].map { |c| c[:commandId] }
    expect(ids).to contain_exactly(running.command_id, exited.command_id)

    filtered = described_class.call(runId: run.run_id, status: "running", server_context: { worker_id: worker.worker_id })
    expect(filtered.structured_content[:commands].map { |c| c[:commandId] }).to eq([ running.command_id ])
  ensure
    Orchestrator::RunCommandRunner.stop(command: running, reason: "spec cleanup") if running
  end

  def create_run_and_worker
    root = Dir.mktmpdir("list-run-commands")
    workspace = Workspace.create!(name: "list-run-commands-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "list-run-commands-#{SecureRandom.hex(4)}", task: "Exercise list_run_commands",
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

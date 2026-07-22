require "rails_helper"

RSpec.describe McpTools::RecordProjectSetupTool do
  it "records findings as durable, project_init-attributed workspace memory" do
    run, worker = create_run_and_worker(role: "project_init")

    response = described_class.call(
      runId: run.run_id,
      findings: [
        { key: "dev-environment", content: "Run `bin/dev` from the repository root.", evidenceRef: "bin/dev" }
      ],
      server_context: { worker_id: worker.worker_id }
    )

    expect(response.error?).to be_falsey
    expect(response.structured_content).to be_a(Hash) # MCP structuredContent must be a JSON object, not a bare array
    entry = run.workspace.workspace_memory_entries.current.find_by!(entry_key: "dev-environment")
    expect(entry.recorded_by).to eq("project_init")
    expect(entry.content).to include("bin/dev")
  end

  it "rejects a worker that is not the project_init role" do
    run, worker = create_run_and_worker(role: "worker")

    response = described_class.call(
      runId: run.run_id,
      findings: [ { key: "dev-environment", content: "Run `bin/dev`.", evidenceRef: "bin/dev" } ],
      server_context: { worker_id: worker.worker_id }
    )

    expect(response.error?).to be(true)
    expect(run.workspace.workspace_memory_entries.current).to be_empty
  end

  def create_run_and_worker(role:)
    root = Dir.mktmpdir("record-project-setup")
    workspace = Workspace.create!(name: "record-project-setup-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "record-project-setup-#{SecureRandom.hex(4)}", task: "Exercise record_project_setup",
      target_root: root, launcher_variant: "claude", status: "running"
    )
    worker = run.workers.create!(
      worker_id: SecureRandom.uuid, role: role, nickname: "#{role}-#{SecureRandom.hex(2)}", reason: "test",
      scope: "project-setup", status: "running", pid: 99_998, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.prompt").to_s,
      log_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.log").to_s,
      last_message_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.last").to_s,
      env_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.env").to_s
    )
    [ run, worker ]
  end
end

require "rails_helper"

RSpec.describe McpTools::RecordProtectedPathsTool do
  it "declares protected source roots on the workspace, attributed to project_init" do
    run, worker = create_run_and_worker(role: "project_init")

    response = described_class.call(
      runId: run.run_id,
      patterns: [ ".", " " ],
      server_context: { worker_id: worker.worker_id }
    )

    expect(response.error?).to be_falsey
    expect(response.structured_content).to be_a(Hash) # MCP structuredContent must be a JSON object, not a bare array
    expect(run.workspace.reload.protected_path_patterns).to eq([ "." ])
  end

  it "replaces any previously declared patterns" do
    run, worker = create_run_and_worker(role: "project_init")
    run.workspace.update!(protected_path_patterns: [ "old/root" ])

    described_class.call(
      runId: run.run_id, patterns: [ "." ],
      server_context: { worker_id: worker.worker_id }
    )

    expect(run.workspace.reload.protected_path_patterns).to eq([ "." ])
  end

  it "rejects a worker that is not the project_init role" do
    run, worker = create_run_and_worker(role: "worker")

    response = described_class.call(
      runId: run.run_id, patterns: [ "." ],
      server_context: { worker_id: worker.worker_id }
    )

    expect(response.error?).to be(true)
    expect(run.workspace.reload.protected_path_patterns).to eq([])
  end

  def create_run_and_worker(role:)
    root = Dir.mktmpdir("record-protected-paths")
    workspace = Workspace.create!(name: "record-protected-paths-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "record-protected-paths-#{SecureRandom.hex(4)}", task: "Exercise record_protected_paths",
      target_root: root, launcher_variant: "claude", status: "running"
    )
    worker = run.workers.create!(
      worker_id: SecureRandom.uuid, role: role, nickname: "#{role}-#{SecureRandom.hex(2)}", reason: "test",
      scope: "project-setup", status: "running", pid: 99_997, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.prompt").to_s,
      log_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.log").to_s,
      last_message_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.last").to_s,
      env_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.env").to_s
    )
    [ run, worker ]
  end
end

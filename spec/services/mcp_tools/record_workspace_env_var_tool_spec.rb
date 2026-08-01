require "rails_helper"

RSpec.describe McpTools::RecordWorkspaceEnvVarTool do
  it "records the env var, attributed to the authenticated worker's own role" do
    run, worker = create_run_and_worker(role: "worker")

    response = described_class.call(
      runId: run.run_id, name: "BUNDLE_WITHOUT", value: "production", evidenceRef: "worker.log:42",
      server_context: { worker_id: worker.worker_id }
    )

    expect(response.error?).to be_falsey
    expect(response.structured_content).to be_a(Hash) # MCP structuredContent must be a JSON object, not a bare array
    entry = run.workspace.workspace_env_vars.find_by!(name: "BUNDLE_WITHOUT")
    expect(entry.value).to eq("production")
    expect(entry.recorded_by).to eq("worker")
  end

  it "is callable by any worker role, not just project_init" do
    run, worker = create_run_and_worker(role: "git")

    response = described_class.call(
      runId: run.run_id, name: "GIT_LFS_SKIP_SMUDGE", value: "1", evidenceRef: "worker.log:7",
      server_context: { worker_id: worker.worker_id }
    )

    expect(response.error?).to be_falsey
    expect(run.workspace.workspace_env_vars.find_by!(name: "GIT_LFS_SKIP_SMUDGE").recorded_by).to eq("git")
  end

  it "rejects a name that is not a valid environment variable name" do
    run, worker = create_run_and_worker(role: "worker")

    response = described_class.call(
      runId: run.run_id, name: "not a valid name", value: "1", evidenceRef: "worker.log:1",
      server_context: { worker_id: worker.worker_id }
    )

    expect(response.error?).to be(true)
    expect(run.workspace.workspace_env_vars).to be_empty
  end

  # Confirmed live (run-20260731-191508-8a58): a worker recorded
  # GEM_HOME="${TMPDIR:-/tmp}/bundler_gems" verbatim, expecting shell
  # expansion that never happens -- Process.spawn substitutes an env value
  # exactly as given, so the next worker's $GEM_HOME was that literal,
  # unexpanded string. Reject the shapes that only make sense pre-expansion.
  it "rejects a value containing unexpanded shell syntax" do
    run, worker = create_run_and_worker(role: "infrastructure")

    response = described_class.call(
      runId: run.run_id, name: "GEM_HOME", value: "${TMPDIR:-/tmp}/bundler_gems", evidenceRef: "worker.log:1",
      server_context: { worker_id: worker.worker_id }
    )

    expect(response.error?).to be(true)
    expect(run.workspace.workspace_env_vars).to be_empty
  end

  def create_run_and_worker(role:)
    root = Dir.mktmpdir("record-workspace-env-var")
    workspace = Workspace.create!(name: "record-workspace-env-var-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "record-workspace-env-var-#{SecureRandom.hex(4)}", task: "Exercise record_workspace_env_var",
      target_root: root, launcher_variant: "claude", status: "running"
    )
    worker = run.workers.create!(
      worker_id: SecureRandom.uuid, role: role, nickname: "#{role}-#{SecureRandom.hex(2)}", reason: "test",
      scope: "env-var-test", status: "running", pid: 99_997, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.prompt").to_s,
      log_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.log").to_s,
      last_message_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.last").to_s,
      env_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.env").to_s
    )
    [ run, worker ]
  end
end

require "rails_helper"

RSpec.describe McpTools::RecordWorkspaceEnvVarTool do
  it "records the env var, attributed to the session's driver" do
    run, session = create_run_and_session(prefix: "record-env-var")

    response = described_class.call(
      runId: run.run_id, name: "BUNDLE_WITHOUT", value: "production", evidenceRef: "session.log:42",
      server_context: { run_session_id: session.id }
    )

    expect(response.error?).to be_falsey
    expect(response.structured_content).to be_a(Hash) # MCP structuredContent must be a JSON object, not a bare array
    entry = run.workspace.workspace_env_vars.find_by!(name: "BUNDLE_WITHOUT")
    expect(entry.value).to eq("production")
    expect(entry.recorded_by).to eq("claude")
  end

  it "rejects a capability belonging to a different run" do
    _run, session = create_run_and_session(prefix: "record-env-var-a")
    other_run = create_run(prefix: "record-env-var-b")

    response = described_class.call(
      runId: other_run.run_id, name: "NOPE", value: "1", evidenceRef: "session.log:1",
      server_context: { run_session_id: session.id }
    )

    expect(response.error?).to be(true)
    expect(other_run.workspace.workspace_env_vars).to be_empty
  end

  it "rejects a name that is not a valid environment variable name" do
    run, session = create_run_and_session(prefix: "record-env-var")

    response = described_class.call(
      runId: run.run_id, name: "not a var", value: "1", evidenceRef: "session.log:9",
      server_context: { run_session_id: session.id }
    )

    expect(response.error?).to be(true)
    expect(run.workspace.workspace_env_vars).to be_empty
  end

  it "rejects a value containing unexpanded shell syntax" do
    run, session = create_run_and_session(prefix: "record-env-var")

    response = described_class.call(
      runId: run.run_id, name: "BUNDLE_PATH", value: "$TMPDIR/bundler_gems", evidenceRef: "session.log:11",
      server_context: { run_session_id: session.id }
    )

    expect(response.error?).to be(true)
    expect(run.workspace.workspace_env_vars).to be_empty
  end
end

require "rails_helper"

RSpec.describe McpTools::RecordProtectedPathsTool do
  it "declares protected source globs on the workspace" do
    run, session = create_run_and_session(prefix: "record-protected-paths")

    response = described_class.call(
      runId: run.run_id,
      patterns: [ "app/**", "db/migrate/**", " " ],
      server_context: { run_session_id: session.id }
    )

    expect(response.error?).to be_falsey
    expect(response.structured_content).to be_a(Hash) # MCP structuredContent must be a JSON object, not a bare array
    expect(run.workspace.reload.protected_path_patterns).to eq(%w[app/** db/migrate/**])
  end

  it "replaces any previously declared patterns" do
    run, session = create_run_and_session(prefix: "record-protected-paths")
    run.workspace.update!(protected_path_patterns: [ "old/root" ])

    described_class.call(
      runId: run.run_id, patterns: [ "app/**" ],
      server_context: { run_session_id: session.id }
    )

    expect(run.workspace.reload.protected_path_patterns).to eq([ "app/**" ])
  end

  it "rejects a capability belonging to a different run" do
    _run, session = create_run_and_session(prefix: "record-protected-paths-a")
    other_run = create_run(prefix: "record-protected-paths-b")

    response = described_class.call(
      runId: other_run.run_id, patterns: [ "app/**" ],
      server_context: { run_session_id: session.id }
    )

    expect(response.error?).to be(true)
    expect(other_run.workspace.reload.protected_path_patterns).to eq([])
  end

  it "rejects a catch-all, negated, or cache pattern" do
    run, session = create_run_and_session(prefix: "record-protected-paths")

    response = described_class.call(
      runId: run.run_id, patterns: [ ".", "!config/*.key", "node_modules/**" ],
      server_context: { run_session_id: session.id }
    )

    expect(response.error?).to be(true)
    expect(run.workspace.reload.protected_path_patterns).to eq([])
  end
end

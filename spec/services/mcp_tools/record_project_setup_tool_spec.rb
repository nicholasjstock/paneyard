require "rails_helper"

RSpec.describe McpTools::RecordProjectSetupTool do
  it "records findings as durable workspace memory that outlives the run" do
    run, session = create_run_and_session(prefix: "record-project-setup")

    response = described_class.call(
      runId: run.run_id,
      findings: [
        { key: "dev-environment", content: "Run `bin/dev` from the repository root.", evidenceRef: "bin/dev" }
      ],
      server_context: { run_session_id: session.id }
    )

    expect(response.error?).to be_falsey
    expect(response.structured_content).to be_a(Hash) # MCP structuredContent must be a JSON object, not a bare array
    entry = run.workspace.workspace_memory_entries.current.find_by!(entry_key: "dev-environment")
    expect(entry.recorded_by).to eq("session")
    expect(entry.content).to include("bin/dev")
  end

  it "rejects a capability belonging to a different run" do
    _run, session = create_run_and_session(prefix: "record-project-setup-a")
    other_run = create_run(prefix: "record-project-setup-b")

    response = described_class.call(
      runId: other_run.run_id,
      findings: [ { key: "dev-environment", content: "Run `bin/dev`.", evidenceRef: "bin/dev" } ],
      server_context: { run_session_id: session.id }
    )

    expect(response.error?).to be(true)
    expect(other_run.workspace.workspace_memory_entries.current).to be_empty
  end
end

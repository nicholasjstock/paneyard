require "rails_helper"

RSpec.describe McpTools::WorkspaceResolution do
  describe ".resolve!" do
    it "prefers an explicit workspace name over everything else" do
      _run, session = create_run_and_session(prefix: "resolve-explicit")
      other = create_workspace(prefix: "resolve-explicit-other")

      resolved = described_class.resolve!(server_context: { run_session_id: session.id }, workspace: other.name)

      expect(resolved).to eq(other)
    end

    it "raises for an unknown workspace name" do
      expect {
        described_class.resolve!(server_context: {}, workspace: "no-such-workspace")
      }.to raise_error(ArgumentError, /no workspace named/)
    end

    it "falls back to the calling run session's own workspace" do
      run, session = create_run_and_session(prefix: "resolve-session")

      resolved = described_class.resolve!(server_context: { run_session_id: session.id })

      expect(resolved).to eq(run.workspace)
    end

    it "falls back to the oldest registered workspace when there is no run session" do
      first = create_workspace(prefix: "resolve-default-a")
      create_workspace(prefix: "resolve-default-b")

      resolved = described_class.resolve!(server_context: {})

      expect(resolved).to eq(first)
    end
  end

  describe ".resolve! with explicit: true (queue_run)" do
    it "refuses to fall back to the oldest workspace from outside a run" do
      create_workspace(prefix: "resolve-explicit-only")

      expect { described_class.resolve!(server_context: {}, explicit: true) }
        .to raise_error(ArgumentError, /workspace is required .* register_workspace/)
    end

    it "still defaults to the calling run session's own workspace" do
      run, session = create_run_and_session(prefix: "resolve-explicit-session")

      expect(described_class.resolve!(server_context: { run_session_id: session.id }, explicit: true)).to eq(run.workspace)
    end
  end

  describe ".run!" do
    it "scopes the run lookup to the resolved workspace" do
      run, session = create_run_and_session(prefix: "resolve-run")

      expect(described_class.run!(server_context: { run_session_id: session.id }, run_id: run.run_id)).to eq(run)
    end

    it "raises when the run does not belong to the resolved workspace" do
      _run, session = create_run_and_session(prefix: "resolve-run-a")
      other_run = create_run(prefix: "resolve-run-b")

      expect {
        described_class.run!(server_context: { run_session_id: session.id }, run_id: other_run.run_id)
      }.to raise_error(ArgumentError, /no run/)
    end
  end
end

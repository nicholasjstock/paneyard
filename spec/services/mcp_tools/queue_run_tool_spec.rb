require "rails_helper"

RSpec.describe McpTools::QueueRunTool do
  it "queues a run in an explicitly named workspace, with no run session behind the call at all" do
    workspace = create_workspace(prefix: "queue-run-explicit")

    response = described_class.call(task: "Fix the flaky spec.", workspace: workspace.name, server_context: {})

    expect(response.error?).to be_falsey
    run = workspace.runs.sole
    expect(run).to have_attributes(task: "Fix the flaky spec.", status: "queued", launcher_variant: "claude", launched_by: "mcp")
  end

  it "defaults to the calling run session's own workspace" do
    run, session = create_run_and_session(prefix: "queue-run-session")

    described_class.call(task: "Follow-up work.", server_context: { run_session_id: session.id })

    expect(run.workspace.runs.find_by(task: "Follow-up work.")).to be_present
  end

  it "rejects a blank task" do
    workspace = create_workspace(prefix: "queue-run-blank")

    response = described_class.call(task: "", workspace: workspace.name, server_context: {})

    expect(response.error?).to be(true)
    expect(workspace.runs).to be_empty
  end

  it "errors on an unknown workspace instead of silently picking a default" do
    response = described_class.call(task: "Do something.", workspace: "no-such-workspace", server_context: {})

    expect(response.error?).to be(true)
  end
end

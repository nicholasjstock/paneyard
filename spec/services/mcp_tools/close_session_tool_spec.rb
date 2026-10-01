require "rails_helper"

RSpec.describe McpTools::CloseSessionTool do
  it "closes the run's live session for operator clients" do
    run, session = create_run_and_session(prefix: "close-tool")
    session.update!(status: "done", outcome: "done", result: "Finished.")
    allow(Orchestrator::RunSessionRunner).to receive(:finish!) do |s, **|
      s.update!(status: "done", ended_at: Time.current)
    end
    allow(Orchestrator::WorktreeJanitor).to receive(:release!).with(run).and_return(false)

    response = described_class.call(runId: run.run_id, workspace: run.workspace.name, server_context: {})

    expect(response.error?).to be_falsey
    expect(response.structured_content).to include(
      runId: run.run_id, status: "completed", outcome: "done", worktree: "kept", worktreeName: run.worktree_name
    )
    expect(session.reload).to be_ended
  end

  it "errors, changing nothing, when the run has no live session" do
    run = create_run(prefix: "close-tool-none", status: "awaiting_review")

    response = described_class.call(runId: run.run_id, workspace: run.workspace.name, server_context: {})

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("no live session")
    expect(run.reload.status).to eq("awaiting_review")
  end

  it "errors for a run that is not in the named workspace" do
    run, _session = create_run_and_session(prefix: "close-tool-elsewhere")
    other = create_workspace(prefix: "close-tool-other")
    allow(Orchestrator::RunSessionRunner).to receive(:finish!)

    response = described_class.call(runId: run.run_id, workspace: other.name, server_context: {})

    expect(response.error?).to be(true)
    expect(Orchestrator::RunSessionRunner).not_to have_received(:finish!)
  end
end

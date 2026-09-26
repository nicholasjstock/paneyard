require "rails_helper"

RSpec.describe McpTools::GetRunTool do
  it "returns detail for a run in the named workspace" do
    run = create_run(prefix: "get-run")

    response = described_class.call(runId: run.run_id, workspace: run.workspace.name, server_context: {})

    expect(response.error?).to be_falsey
    expect(response.structured_content[:runId]).to eq(run.run_id)
  end

  it "errors when the run belongs to a different workspace" do
    run = create_run(prefix: "get-run-other")
    other_workspace = create_workspace(prefix: "get-run-other-workspace")

    response = described_class.call(runId: run.run_id, workspace: other_workspace.name, server_context: {})

    expect(response.error?).to be(true)
  end
end

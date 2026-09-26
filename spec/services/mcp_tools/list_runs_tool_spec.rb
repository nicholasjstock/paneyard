require "rails_helper"

RSpec.describe McpTools::ListRunsTool do
  it "lists only the resolved workspace's active runs by default" do
    workspace = create_workspace(prefix: "list-runs")
    active = create_run(workspace:, prefix: "list-runs-active", status: "running")
    create_run(workspace:, prefix: "list-runs-done", status: "completed")
    create_run(prefix: "list-runs-other-workspace")

    response = described_class.call(workspace: workspace.name, server_context: {})

    expect(response.structured_content[:runs].map { |r| r[:runId] }).to contain_exactly(active.run_id)
  end

  it "includes finished runs when asked" do
    workspace = create_workspace(prefix: "list-runs-finished")
    done = create_run(workspace:, prefix: "list-runs-finished-done", status: "completed")

    response = described_class.call(workspace: workspace.name, includeFinished: true, server_context: {})

    expect(response.structured_content[:runs].map { |r| r[:runId] }).to include(done.run_id)
  end
end

require "rails_helper"

RSpec.describe McpTools::UpdateWorkspaceLayoutTool do
  let(:workspace) { create_workspace(prefix: "update-layout") }

  it "validates and stores a canonical layout" do
    response = described_class.call(
      workspace: workspace.name,
      layout: "tabs:\n  - panes:\n      - agent\n      - name: shell\n        split: { of: agent, direction: down }\n",
      server_context: {}
    )

    expect(response).not_to be_error
    expect(response.structured_content).to include(workspace: workspace.name, usingDefault: false)
    expect(workspace.reload.layout).to include("name: shell", "direction: down")
  end

  it "changes nothing when the layout is invalid" do
    workspace.update!(layout: "tabs:\n  - panes:\n      - agent\n")

    response = described_class.call(workspace: workspace.name, layout: "tabs: []", server_context: {})

    expect(response).to be_error
    expect(response.structured_content).to include(error: "workspace_layout_invalid")
    expect(response.structured_content[:problems]).to include(/non-empty/)
    expect(workspace.reload.layout).to include("agent")
  end

  it "resets an existing layout to the default" do
    workspace.update!(layout: "tabs:\n  - panes:\n      - agent\n")

    response = described_class.call(workspace: workspace.name, layout: "", server_context: {})

    expect(response).not_to be_error
    expect(response.structured_content).to include(usingDefault: true, layoutYaml: nil)
    expect(workspace.reload.layout).to be_nil
  end
end

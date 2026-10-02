require "rails_helper"

RSpec.describe McpTools::ListWorkspacesTool do
  it "lists every workspace with its repository, default base branch, default flag, and in-flight run count" do
    busy = create_workspace(prefix: "list-workspaces-busy")
    idle = create_workspace(prefix: "list-workspaces-idle")
    create_run(workspace: busy, prefix: "list-workspaces-running", status: "running")
    create_run(workspace: busy, prefix: "list-workspaces-done", status: "completed")

    workspaces = described_class.call(server_context: {}).structured_content[:workspaces].index_by { |w| w[:name] }

    expect(workspaces[busy.name]).to include(repositoryPath: busy.repository_path, defaultBaseBranch: "main", activeRuns: 1)
    expect(workspaces[idle.name]).to include(repositoryPath: idle.repository_path, defaultBaseBranch: "main", activeRuns: 0)
    expect(workspaces[busy.name]).to include(layoutYaml: nil, defaultLayoutYaml: Orchestrator::WorkspaceLayout::DEFAULT_YAML)
    expect(workspaces.values.count { |w| w[:isDefault] }).to eq(1)
    expect(workspaces.values.find { |w| w[:isDefault] }[:name]).to eq(Workspace.default.name)
  end
end

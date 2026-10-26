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
    expect(workspaces[busy.name]).to include(lobby: nil)
  end

  it "shows a workspace's open lobby and whether its agent is still there" do
    workspace = create_workspace(prefix: "list-workspaces-lobby")
    workspace.lobbies.create!(branch: "release", driver: "codex", model: "gpt-5.5", herdr_workspace_id: "w9",
      herdr_pane_id: "w9:p1", pid: 4242)
    allow(Orchestrator::Runner::Herdr).to receive(:agent_get).with("w9:p1").and_return("agent_status" => "idle")
    allow(Orchestrator::Runner.for(workspace)).to receive(:process_alive?).with(4242).and_return(false)

    listed = described_class.call(server_context: {}).structured_content[:workspaces].find { |w| w[:name] == workspace.name }

    expect(listed[:lobby]).to eq(branch: "release", herdrWorkspace: "w9", driver: "codex", model: "gpt-5.5", live: false)
  end
end

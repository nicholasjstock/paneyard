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

  it "lists the runners a workspace's jobs can run on, local first, with its checkout on each or none yet" do
    workspace = create_workspace(prefix: "list-workspaces-runners")
    laptop = RegisteredRunner.create!(name: "laptop", kind: "remote", url: "http://laptop.tailnet:3100")
    RegisteredRunner.create!(name: "nas", kind: "remote", url: "http://nas.tailnet:3100", projects_dir: "/volume1/src")

    listed = -> { described_class.call(server_context: {}).structured_content[:workspaces].find { |w| w[:name] == workspace.name } }
    expect(listed.call[:runners]).to eq([
      { name: "local", kind: "local", repositoryPath: workspace.repository_path, checkedOut: true },
      { name: "nas", kind: "remote", repositoryPath: nil, checkedOut: false }
    ])

    workspace.checkouts.create!(runner: laptop, repository_path: "/Users/me/code/app")
    expect(listed.call[:runners]).to eq([
      { name: "local", kind: "local", repositoryPath: workspace.repository_path, checkedOut: true },
      { name: "laptop", kind: "remote", repositoryPath: "/Users/me/code/app", checkedOut: true },
      { name: "nas", kind: "remote", repositoryPath: nil, checkedOut: false }
    ])
  end

  it "lists a workspace checked out only on a remote runner, with no local path" do
    laptop = RegisteredRunner.create!(name: "laptop", kind: "remote", url: "http://laptop.tailnet:3100")
    workspace = Workspace.new(name: "remote-only", origin_url: "git@github.com:me/remote-only.git")
    workspace.record_checkout(laptop, "/Users/me/code/remote-only")
    workspace.save!

    listed = described_class.call(server_context: {}).structured_content[:workspaces].find { |w| w[:name] == "remote-only" }
    expect(listed).to include(repositoryPath: nil, originUrl: "git@github.com:me/remote-only.git")
    expect(listed[:runners]).to eq([
      { name: "local", kind: "local", repositoryPath: nil, checkedOut: false },
      { name: "laptop", kind: "remote", repositoryPath: "/Users/me/code/remote-only", checkedOut: true }
    ])
  end
end

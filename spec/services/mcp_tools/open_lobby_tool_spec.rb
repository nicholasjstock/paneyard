require "rails_helper"

RSpec.describe McpTools::OpenLobbyTool do
  let(:workspace) { create_workspace(prefix: "open-lobby") }

  def call(**arguments)
    described_class.call(server_context: {}, workspace: workspace.name, **arguments)
  end

  it "opens the named workspace's lobby and says where" do
    lobby = workspace.lobbies.create!(branch: "release", driver: "claude", model: "opus", herdr_workspace_id: "w9")
    allow(Orchestrator::LobbyOpen).to receive(:call)
      .with(workspace, branch: "release", driver: nil, model: nil)
      .and_return(state: "opened", lobby:, switched_from: "main")

    response = call(branch: "release")

    expect(response.error?).to be(false)
    expect(response.structured_content).to eq(
      state: "opened", workspace: workspace.name, repositoryPath: workspace.repository_path, branch: "release",
      switchedFrom: "main", herdrWorkspace: "w9", driver: "claude", model: "opus"
    )
  end

  it "answers a lobby busy on another branch, or a checkout it could not switch, with an error" do
    allow(Orchestrator::LobbyOpen).to receive(:call).and_raise(Orchestrator::LobbyOpen::Busy, "open on main")
    expect(call(branch: "release").structured_content).to include(error: "lobby_busy", message: "open on main")

    allow(Orchestrator::LobbyOpen).to receive(:call).and_raise(Orchestrator::Runner::Error, "uncommitted changes")
    expect(call(branch: "release").structured_content).to include(error: "lobby_failed", message: "uncommitted changes")
  end

  it "needs a workspace that exists" do
    response = described_class.call(server_context: {}, workspace: "nope")

    expect(response.error?).to be(true)
    expect(response.structured_content[:message]).to match(/no workspace named "nope"/)
  end
end

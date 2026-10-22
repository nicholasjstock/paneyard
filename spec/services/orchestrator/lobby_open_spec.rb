require "rails_helper"

RSpec.describe Orchestrator::LobbyOpen do
  let(:workspace) { create_workspace(default_base_branch: "main") }
  let(:runner) { instance_double(Orchestrator::Runner::Local) }

  before do
    allow(Orchestrator::Runner).to receive(:for).and_return(runner)
    allow(runner).to receive(:switch_checkout) do |branch:, **|
      { "branch" => branch, "previous_branch" => "main", "switched" => branch != "main" }
    end
    allow(runner).to receive(:open_checkout_workspace)
      .and_return("workspace_id" => "w9", "tab_id" => "w9:t1", "pane_id" => "w9:p1")
    allow(runner).to receive(:open_session)
      .and_return("workspace_id" => "w9", "tab_id" => "w9:t1", "pane_id" => "w9:p1", "mcp_config_path" => "/rt/mcp.json", "prompt_path" => nil)
    allow(runner).to receive(:launch_agent).and_return("pid" => 4242, "lost_prompts" => [])
    allow(runner).to receive(:close_workspace)
    allow(runner).to receive(:checkout_branch).and_return("main")
    allow(runner).to receive(:agent_state).and_return("agent_status" => "idle")
    allow(runner).to receive(:process_alive?).and_return(true)
  end

  def open_lobby(**arguments)
    described_class.call(workspace, **arguments)
  end

  it "opens the lobby on the branch the checkout is on, not the workspace default: an agent on /mcp/admin, no prompt" do
    allow(runner).to receive(:checkout_branch).with(repository_path: workspace.repository_path).and_return("feature/x")
    allow(runner).to receive(:switch_checkout).and_return("branch" => "feature/x", "previous_branch" => "feature/x", "switched" => false)

    opened = open_lobby

    expect(opened).to include(state: "opened", switched_from: nil)
    expect(opened.fetch(:lobby)).to have_attributes(branch: "feature/x", driver: "claude", model: "opus",
      herdr_workspace_id: "w9", herdr_pane_id: "w9:p1", pid: 4242, closed_at: nil)
    expect(runner).to have_received(:open_checkout_workspace)
      .with(repository_path: workspace.repository_path, label: "#{workspace.name} lobby (feature/x)")
    expect(runner).to have_received(:launch_agent).with(
      hash_including(cwd: workspace.repository_path, prompt: nil, capability_token: nil, mcp_endpoint: "admin",
        herdr_pane_id: "w9:p1"),
      pane_id: "w9:p1", mcp_config_path: "/rt/mcp.json"
    )
  end

  it "switches the checkout to the branch asked for, and says from which" do
    opened = open_lobby(branch: "release", driver: "codex", model: "gpt-5.5")

    expect(runner).to have_received(:switch_checkout).with(repository_path: workspace.repository_path, branch: "release")
    expect(opened).to include(state: "opened", switched_from: "main")
    expect(opened.fetch(:lobby)).to have_attributes(branch: "release", driver: "codex", model: "gpt-5.5")
  end

  it "finds the lobby already open on that branch, touching nothing" do
    first = open_lobby.fetch(:lobby)

    again = open_lobby(branch: "main")

    expect(again).to eq(state: "already_open", lobby: first, switched_from: nil)
    expect(runner).to have_received(:switch_checkout).once
    expect(runner).to have_received(:launch_agent).once
  end

  it "finds a live lobby wherever it is when no branch is named" do
    first = open_lobby(branch: "release").fetch(:lobby)

    expect(open_lobby).to eq(state: "already_open", lobby: first, switched_from: nil)
    expect(runner).to have_received(:switch_checkout).once
  end

  it "asks for a branch when the checkout is on a detached HEAD and none is named" do
    allow(runner).to receive(:checkout_branch).and_return(nil)

    expect { open_lobby }.to raise_error(ArgumentError, /detached HEAD; name the branch/)
    expect(workspace.open_lobby).to be_nil
  end

  it "refuses to switch the checkout under a live lobby on another branch" do
    open_lobby

    expect { open_lobby(branch: "release") }.to raise_error(described_class::Busy, /open on main\. Quit its agent/)
    expect(runner).to have_received(:switch_checkout).once
  end

  it "replaces a lobby whose agent is gone, closing what was left of its herdr workspace" do
    old = open_lobby.fetch(:lobby)
    allow(runner).to receive(:process_alive?).with(4242).and_return(false)
    allow(runner).to receive(:open_checkout_workspace)
      .and_return("workspace_id" => "w10", "tab_id" => "w10:t1", "pane_id" => "w10:p1")

    opened = open_lobby(branch: "release")

    expect(runner).to have_received(:close_workspace).with("w9")
    expect(old.reload.closed_at).to be_present
    expect(opened).to include(state: "opened", switched_from: "main")
    expect(workspace.open_lobby).to eq(opened.fetch(:lobby))
  end

  it "takes a lobby herdr cannot be asked about as live" do
    open_lobby
    allow(runner).to receive(:agent_state).and_raise(Orchestrator::Runner::Unreachable, "herdr is not running")

    expect(described_class.status(workspace)).to include(live: true)
  end

  it "closes the herdr workspace and forgets the lobby when its agent never starts" do
    allow(runner).to receive(:launch_agent).and_raise(Orchestrator::Runner::LaunchError, "never ready")

    expect { open_lobby }.to raise_error(Orchestrator::Runner::LaunchError, "never ready")
    expect(runner).to have_received(:close_workspace).with("w9")
    expect(workspace.open_lobby).to be_nil
  end

  it "opens nothing when the checkout cannot be switched" do
    allow(runner).to receive(:switch_checkout).and_raise(Orchestrator::Runner::Error, "uncommitted changes")

    expect { open_lobby(branch: "release") }.to raise_error(Orchestrator::Runner::Error, "uncommitted changes")
    expect(runner).not_to have_received(:open_checkout_workspace)
    expect(workspace.open_lobby).to be_nil
  end

  it "counts a lobby still being opened as live, and one that never finished as gone" do
    lobby = workspace.lobbies.create!(branch: "main", driver: "claude")

    expect(described_class.status(workspace)).to eq(lobby:, live: true)

    lobby.update!(created_at: 11.minutes.ago)
    expect(described_class.status(workspace)).to eq(lobby:, live: false)
  end

  it "names the agent the way herdr accepts, whatever the workspace is called" do
    workspace.update!(name: "Gembani.com Site With A Very Long Name")

    open_lobby

    expect(runner).to have_received(:launch_agent).with(hash_including(run_id: "lobby-gembani-com-site-with-a-ve"), any_args)
    expect(described_class.agent_name(workspace)).to match(FakeHerdr::Server::AGENT_NAME)
  end

  it "rejects a bad branch name or driver before touching anything" do
    expect { open_lobby(branch: "-x") }.to raise_error(ArgumentError, /not a valid branch name/)
    expect { open_lobby(driver: "cursor") }.to raise_error(ArgumentError, /driver must be one of/)
    expect(runner).not_to have_received(:switch_checkout)
  end
end

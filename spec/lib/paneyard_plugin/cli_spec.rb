require "spec_helper"
require "stringio"
require "tmpdir"
require_relative "../../../lib/paneyard_plugin/cli"

# The popups' conversations, against a stand-in daemon and client: what the
# operator types in, what gets queued, registered or closed. Booting the real
# app behind them is bin/herdr-plugin's job, covered by the daemon spec and by
# trying the plugin in herdr.
RSpec.describe PaneyardPlugin::Cli do
  let(:state) { Dir.mktmpdir("paneyard-plugin-cli") }
  let(:daemon) do
    instance_double(PaneyardPlugin::Daemon, status: nil,
      ensure_running: PaneyardPlugin::Daemon::Result.new(outcome: :running, pid: 1, port: 7999, url: "http://127.0.0.1:7999"))
  end
  let(:client) { instance_double(PaneyardPlugin::Client) }
  let(:out) { StringIO.new }
  let(:herdr_calls) { [] }

  def run_cli(command, input: "", context: {})
    env = {
      "HERDR_PLUGIN_STATE_DIR" => state, "HERDR_PLUGIN_CONFIG_DIR" => state, "PATH" => ENV["PATH"],
      "HERDR_PLUGIN_CONTEXT_JSON" => JSON.generate(context)
    }
    cli = described_class.new(env:, out:, input: StringIO.new(input))
    allow(cli).to receive(:herdr) { |*args| herdr_calls << args }
    cli.call([ command ])
  end

  before do
    allow(PaneyardPlugin::Daemon).to receive(:new).and_return(daemon)
    allow(PaneyardPlugin::Client).to receive(:new).with("http://127.0.0.1:7999").and_return(client)
  end

  after { FileUtils.rm_rf(state) }

  describe "queue-ui" do
    let(:workspace) { { "id" => 3, "name" => "app", "repositoryPath" => "/code/app", "defaultBaseBranch" => "main" } }

    before { allow(PaneyardPlugin::WorkspaceMatch).to receive(:repository_of).and_return([ nil, nil ]) }

    it "queues a multi-line task in the workspace the pane is in, from its default base branch" do
      allow(client).to receive(:workspaces).and_return([ workspace ])
      allow(client).to receive(:queue).and_return("runId" => "run-1", "baseBranch" => "main", "queuedBehind" => 0,
        "capacity" => { "inFlight" => 1, "limit" => 4 })

      status = run_cli("queue-ui", input: "Fix the flaky spec.\nRun it ten times.\n\n\ncodex\n\n",
        context: { "focused_pane_cwd" => "/code/app/spec" })

      expect(status).to eq(0)
      expect(client).to have_received(:queue)
        .with(task: "Fix the flaky spec.\nRun it ten times.", workspace: "app", base_branch: nil, driver: "codex")
      expect(out.string).to include("Queue a task in app", "Base branch (Enter for main)", "Queued run-1 from main.")
    end

    it "offers the branch the pane is on, and queues from the one the operator types" do
      allow(PaneyardPlugin::WorkspaceMatch).to receive(:repository_of).and_return([ "/code/app", "feature/payments" ])
      allow(client).to receive(:workspaces).and_return([ workspace ])
      allow(client).to receive(:queue).and_return("runId" => "run-3", "baseBranch" => "feature/payments", "capacity" => {})

      # A pane in a herdr worktree of the repository, wherever herdr put it.
      run_cli("queue-ui", input: "Task\n\nfeature/payments\n\n\n", context: { "focused_pane_cwd" => "/Users/me/.herdr/worktrees/app/x" })

      expect(out.string).to include("Base branch (Enter for main; this pane is on feature/payments)")
      expect(client).to have_received(:queue).with(task: "Task", workspace: "app", base_branch: "feature/payments", driver: nil)
    end

    it "registers the pane's repository first when it is not a workspace yet" do
      allow(PaneyardPlugin::WorkspaceMatch).to receive(:repository_of).and_return([ "/code/other", "main" ])
      allow(client).to receive(:workspaces).and_return([ workspace ])
      allow(client).to receive(:register).and_return("name" => "other", "repositoryPath" => "/code/other", "defaultBaseBranch" => "main")
      allow(client).to receive(:queue).and_return("runId" => "run-2", "queuedBehind" => 2, "capacity" => {})

      run_cli("queue-ui", input: "Task\n\n\n\n\n", context: { "focused_pane_cwd" => "/code/other/lib" })

      expect(client).to have_received(:register).with(path: "/code/other")
      expect(client).to have_received(:queue).with(task: "Task", workspace: "other", base_branch: nil, driver: nil)
    end

    it "shows what to fix, and queues nothing, when the directory cannot be a workspace" do
      allow(client).to receive(:workspaces).and_return([])
      allow(client).to receive(:register).and_raise(PaneyardSandbox::McpClient::ToolError.new("register_workspace failed",
        "message" => "Nothing was registered.", "problems" => [ { "code" => "not_git", "message" => "Clone the repository first." } ]))
      allow(client).to receive(:queue)

      run_cli("queue-ui", input: "\n", context: { "focused_pane_cwd" => "/code/plain" })

      expect(out.string).to include("Nothing was changed", "1. Clone the repository first.")
      expect(client).not_to have_received(:queue)
    end

    it "queues nothing when the task is left empty" do
      allow(client).to receive(:workspaces).and_return([ workspace ])
      allow(client).to receive(:queue)

      run_cli("queue-ui", input: "", context: { "focused_pane_cwd" => "/code/app/main" })

      expect(out.string).to include("Nothing queued.")
      expect(client).not_to have_received(:queue)
    end

    it "keeps an error on screen until a key is pressed, since the popup closes when it exits" do
      allow(daemon).to receive(:ensure_running).and_raise(PaneyardPlugin::Error, "Paneyard exited while starting.")

      status = run_cli("queue-ui", context: { "focused_pane_cwd" => "/code/app/main" })

      expect(status).to eq(1)
      expect(out.string).to include("Paneyard: Paneyard exited while starting.", "Press Enter to close.")
    end
  end

  describe "close-ui" do
    let(:workspace) { { "id" => 3, "name" => "app", "repositoryPath" => "/code/app", "defaultBaseBranch" => "main" } }
    let(:run) { { "runId" => "run-9", "status" => "running", "session" => { "live" => true, "herdrWorkspace" => "w5" } } }

    before do
      allow(client).to receive(:runs).and_return([ [ workspace, { "runs" => [ run ] } ] ])
      allow(client).to receive(:run).with("run-9", workspace: "app").and_return(run)
    end

    it "closes the session of the run whose herdr workspace it was invoked in, once confirmed" do
      allow(client).to receive(:close).and_return("status" => "completed", "worktree" => "kept", "worktreeName" => "fix-9")

      run_cli("close-ui", input: "y\n\n", context: { "workspace_id" => "w5" })

      expect(client).to have_received(:close).with("run-9", workspace: "app")
      expect(out.string).to include("Closed. Run completed.", "Kept its worktree fix-9")
    end

    it "closes nothing without a yes" do
      allow(client).to receive(:close)

      run_cli("close-ui", input: "\n\n", context: { "workspace_id" => "w5" })

      expect(client).not_to have_received(:close)
      expect(out.string).to include("Left it running.")
    end

    it "says so outside a run's herdr workspace" do
      allow(client).to receive(:close)

      run_cli("close-ui", input: "\n", context: { "workspace_id" => "w1" })

      expect(out.string).to include("not a Paneyard run's")
      expect(client).not_to have_received(:close)
    end
  end

  it "shows the MCP URL as a notification, for an action whose output nobody sees" do
    run_cli("mcp-url")

    expect(out.string).to eq("http://127.0.0.1:7999/mcp/admin\n")
    expect(herdr_calls).to eq([ [ "notification", "show", "Paneyard MCP", "--body", "http://127.0.0.1:7999/mcp/admin" ] ])
  end

  it "tells the operator when Paneyard had to move to another port" do
    allow(daemon).to receive(:ensure_running).and_return(PaneyardPlugin::Daemon::Result.new(
      outcome: :started, pid: 1, port: 7999, url: "http://127.0.0.1:7999", previous_port: 7001
    ))

    run_cli("start")

    expect(herdr_calls.first).to include("Paneyard moved to port 7999")
  end
end

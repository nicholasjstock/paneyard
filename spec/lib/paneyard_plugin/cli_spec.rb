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
    yield cli if block_given?
    cli.call([ command ])
  end

  before do
    allow(PaneyardPlugin::Daemon).to receive(:new).and_return(daemon)
    allow(PaneyardPlugin::Client).to receive(:new).with("http://127.0.0.1:7999").and_return(client)
  end

  after { FileUtils.rm_rf(state) }

  describe "menu-ui" do
    it "routes one menu choice without requiring separate global key bindings" do
      run_cli("menu-ui", input: "l\n") do |cli|
        expect(cli).to receive(:layout_ui)
      end

      expect(out.string).to include("Queue a task here", "Browse runs and reports", "Edit this workspace's layout")
    end

    it "closes without doing anything when no choice is made" do
      run_cli("menu-ui") do |cli|
        expect(cli).not_to receive(:queue_ui)
        expect(cli).not_to receive(:runs_ui)
      end

      expect(out.string).to include("Cancelled.")
    end
  end

  describe "queue-ui" do
    let(:workspace) { { "id" => 3, "name" => "app", "repositoryPath" => "/code/app", "defaultBaseBranch" => "main" } }

    before { allow(PaneyardPlugin::WorkspaceMatch).to receive(:repository_of).and_return([ nil, nil ]) }

    it "queues a multi-line task in the workspace the pane is in, from its default base branch off any branch" do
      allow(client).to receive(:workspaces).and_return([ workspace ])
      allow(client).to receive(:queue).and_return("runId" => "run-1", "baseBranch" => "main", "queuedBehind" => 0,
        "capacity" => { "inFlight" => 1, "limit" => 4 })

      status = run_cli("queue-ui", input: "Fix the flaky spec.\nRun it ten times.\n\n\ncodex\n\n",
        context: { "focused_pane_cwd" => "/code/app/spec" })

      expect(status).to eq(0)
      expect(client).to have_received(:queue)
        .with(task: "Fix the flaky spec.\nRun it ten times.", workspace: "app", base_branch: "main", driver: "codex")
      expect(out.string).to include("PANEYARD  /  NEW RUN", "Base branch (Enter for main)", "Queued run-1 from main.")
    end

    it "starts from the branch the pane is on when Enter is pressed" do
      allow(PaneyardPlugin::WorkspaceMatch).to receive(:repository_of).and_return([ "/code/app", "feature/payments" ])
      allow(client).to receive(:workspaces).and_return([ workspace ])
      allow(client).to receive(:queue).and_return("runId" => "run-3", "baseBranch" => "feature/payments", "capacity" => {})

      # A pane in a herdr worktree of the repository, wherever herdr put it.
      run_cli("queue-ui", input: "Task\n\n\n\n\n", context: { "focused_pane_cwd" => "/Users/me/.herdr/worktrees/app/x" })

      expect(out.string).to include("Base branch (Enter for feature/payments; workspace default: main)")
      expect(client).to have_received(:queue).with(task: "Task", workspace: "app", base_branch: "feature/payments", driver: nil)
    end

    it "queues from the branch the operator types instead" do
      allow(PaneyardPlugin::WorkspaceMatch).to receive(:repository_of).and_return([ "/code/app", "feature/payments" ])
      allow(client).to receive(:workspaces).and_return([ workspace ])
      allow(client).to receive(:queue).and_return("runId" => "run-5", "baseBranch" => "main", "capacity" => {})

      run_cli("queue-ui", input: "Task\n\nmain\n\n\n", context: { "focused_pane_cwd" => "/code/app" })

      expect(client).to have_received(:queue).with(task: "Task", workspace: "app", base_branch: "main", driver: nil)
    end

    it "registers the pane's repository first when it is not a workspace yet" do
      allow(PaneyardPlugin::WorkspaceMatch).to receive(:repository_of).and_return([ "/code/other", "main" ])
      allow(client).to receive(:workspaces).and_return([ workspace ])
      allow(client).to receive(:register).and_return("name" => "other", "repositoryPath" => "/code/other", "defaultBaseBranch" => "main")
      allow(client).to receive(:queue).and_return("runId" => "run-2", "queuedBehind" => 2, "capacity" => {})

      run_cli("queue-ui", input: "Task\n\n\n\n\n", context: { "focused_pane_cwd" => "/code/other/lib" })

      expect(client).to have_received(:register).with(path: "/code/other")
      expect(client).to have_received(:queue).with(task: "Task", workspace: "other", base_branch: "main", driver: nil)
    end

    it "asks for the base branch again, keeping the task, when the one typed does not exist" do
      allow(client).to receive(:workspaces).and_return([ workspace ])
      calls = 0
      allow(client).to receive(:queue) do |**args|
        calls += 1
        if calls == 1
          raise PaneyardSandbox::McpClient::ToolError.new("queue_run failed",
            "error" => "base_branch_invalid", "message" => "Base branch `nope`: there is no local branch `nope`.")
        end
        { "runId" => "run-4", "baseBranch" => args[:base_branch], "capacity" => {} }
      end

      run_cli("queue-ui", input: "Task\n\nnope\n\nmain\n\n", context: { "focused_pane_cwd" => "/code/app" })

      expect(client).to have_received(:queue).with(task: "Task", workspace: "app", base_branch: "nope", driver: nil)
      expect(client).to have_received(:queue).with(task: "Task", workspace: "app", base_branch: "main", driver: nil)
      expect(out.string).to include("no local branch `nope`", "Queued run-4 from main.")
    end

    it "says it registered the repository on the task screen, which clears what came before" do
      allow(PaneyardPlugin::WorkspaceMatch).to receive(:repository_of).and_return([ "/code/other", "main" ])
      allow(client).to receive(:workspaces).and_return([])
      allow(client).to receive(:register).and_return("name" => "other", "repositoryPath" => "/code/other", "defaultBaseBranch" => "main")

      run_cli("queue-ui", input: "", context: { "focused_pane_cwd" => "/code/other" })

      expect(out.string.split("PANEYARD  /  NEW RUN").last).to include("Registered as a new workspace")
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

    it "submits on Enter and inserts a line on Shift-Enter in a terminal" do
      input = StringIO.new("First line\nSecond line\r")
      input.define_singleton_method(:tty?) { true }
      input.define_singleton_method(:raw) { |&block| block.call }
      input.define_singleton_method(:getch) { getc }
      terminal = StringIO.new
      terminal.define_singleton_method(:tty?) { true }
      cli = described_class.new(env: {}, out: terminal, input:)

      expect(cli.send(:read_task)).to eq("First line\nSecond line")
      expect(terminal.string).to include("First line", "Second line")
      # Still in raw mode: Enter's newline needs its own carriage return.
      expect(terminal.string).to end_with("\r\n")
    end

    it "repaints while backspacing across a line boundary" do
      input = StringIO.new("First\nxy\u007f\u007f\u007f line\r")
      input.define_singleton_method(:tty?) { true }
      input.define_singleton_method(:raw) { |&block| block.call }
      input.define_singleton_method(:getch) { getc }
      terminal = StringIO.new
      terminal.define_singleton_method(:tty?) { true }
      cli = described_class.new(env: {}, out: terminal, input:)

      expect(cli.send(:read_task)).to eq("First line")
      expect(terminal.string.scan("\e[u\e[J").length).to be > 3
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

  describe "setup-ui" do
    let(:url) { "http://127.0.0.1:7999/mcp/admin" }

    it "asks before configuring every detected client" do
      commands = []
      run_cli("setup-ui", input: "y\n\n") do |cli|
        allow(cli).to receive(:executable?).with("claude").and_return(true)
        allow(cli).to receive(:executable?).with("codex").and_return(true)
        allow(cli).to receive(:run_command) do |*argv|
          commands << argv
          if argv.take(4) == [ "codex", "mcp", "get", "paneyard" ]
            { success: false, output: "", error: "not found" }
          elsif argv.take(4) == [ "claude", "mcp", "get", "paneyard" ]
            { success: false, output: "", error: "not found" }
          else
            { success: true, output: "", error: "" }
          end
        end
      end

      expect(commands).to include(
        [ "claude", "mcp", "add", "--transport", "http", "-s", "user", "paneyard", url ],
        [ "codex", "mcp", "add", "paneyard", "--url", url ]
      )
      expect(out.string).to include("✓ Claude Code detected", "✓ Codex detected",
        "✓ Paneyard MCP configured for Claude Code", "✓ Paneyard MCP configured for Codex")
    end

    it "changes nothing when the operator declines" do
      run_cli("setup-ui", input: "n\n\n") do |cli|
        allow(cli).to receive(:executable?).and_return(true)
        expect(cli).not_to receive(:run_command)
      end

      expect(out.string).to include("No configuration changed.", "Manual setup:", "claude mcp add", "codex mcp add")
    end

    it "recognizes current entries and does not add duplicates" do
      run_cli("setup-ui", input: "\n\n") do |cli|
        allow(cli).to receive(:executable?).and_return(true)
        allow(cli).to receive(:run_command) do |*argv|
          case argv.first
          when "claude"
            { success: true, output: "Scope: User config\nType: http\nURL: #{url}\n", error: "" }
          when "codex"
            { success: true, output: JSON.generate("transport" => { "url" => url }), error: "" }
          end
        end
      end

      expect(out.string).to include("already configured for Claude Code", "already configured for Codex")
      expect(out.string).not_to include("MCP configured for")
    end

    it "continues when one client fails" do
      run_cli("setup-ui", input: "\n\n") do |cli|
        allow(cli).to receive(:executable?).and_return(true)
        allow(cli).to receive(:run_command) do |*argv|
          if argv[1..3] == [ "mcp", "get", "paneyard" ]
            { success: false, output: "", error: "not found" }
          elsif argv.first == "claude"
            { success: false, output: "", error: "permission denied\n" }
          else
            { success: true, output: "", error: "" }
          end
        end
      end

      expect(out.string).to include("Could not configure Claude Code: permission denied",
        "Paneyard MCP configured for Codex")
    end

    it "updates a stale entry and restores it if adding the new URL fails" do
      old_url = "http://127.0.0.1:7001/mcp/admin"
      commands = []
      run_cli("setup-ui", input: "\n\n") do |cli|
        allow(cli).to receive(:executable?).with("claude").and_return(true)
        allow(cli).to receive(:executable?).with("codex").and_return(false)
        allow(cli).to receive(:run_command) do |*argv|
          commands << argv
          case argv
          when [ "claude", "mcp", "get", "paneyard" ]
            { success: true, output: "Scope: User config\nURL: #{old_url}\n", error: "" }
          when [ "claude", "mcp", "add", "--transport", "http", "-s", "user", "paneyard", url ]
            { success: false, output: "", error: "write failed" }
          else
            { success: true, output: "", error: "" }
          end
        end
      end

      expect(commands).to include(
        [ "claude", "mcp", "remove", "-s", "user", "paneyard" ],
        [ "claude", "mcp", "add", "--transport", "http", "-s", "user", "paneyard", old_url ]
      )
      expect(out.string).to include("Could not configure Claude Code: write failed (restored its previous entry).")
    end

    it "reports no clients without treating that as an error" do
      status = run_cli("setup-ui", input: "\n") do |cli|
        allow(cli).to receive(:executable?).and_return(false)
      end

      expect(status).to eq(0)
      expect(out.string).to include("No supported agent CLIs", "Manual setup:")
    end
  end

  it "shows the MCP URL as a notification, for an action whose output nobody sees" do
    run_cli("mcp-url")

    expect(out.string).to eq("http://127.0.0.1:7999/mcp/admin\n")
    expect(herdr_calls).to eq([ [ "notification", "show", "Paneyard MCP", "--body", "http://127.0.0.1:7999/mcp/admin" ] ])
  end

  describe "layout-ui" do
    let(:default_layout) { "tabs:\n  - panes:\n      - agent\n" }
    let(:workspace) do
      {
        "id" => 3, "name" => "app", "repositoryPath" => "/code/app", "defaultBaseBranch" => "main",
        "layoutYaml" => nil, "defaultLayoutYaml" => default_layout
      }
    end

    it "builds, previews and saves the matching workspace's layout from one of its worktrees" do
      allow(client).to receive(:workspaces).and_return([ workspace ])
      allow(client).to receive(:update_layout).and_return("usingDefault" => false)
      allow(PaneyardPlugin::WorkspaceMatch).to receive(:repository_of)
        .with("/herdr/worktrees/app/fix").and_return([ "/code/app", "paneyard/fix" ])

      run_cli("layout-ui", input: "a\nshell\n\n1\nright\n\ns\n\n",
        context: { "focused_pane_cwd" => "/herdr/worktrees/app/fix" })

      expect(client).to have_received(:update_layout).with(workspace: "app", layout: include("name: shell"))
      expect(out.string).to include("app layout", "1.1 └─ agent [root]", "1.2 └─ shell [right of agent]", "Saved the layout.")
    end

    it "resets to the default when the edited file matches the default" do
      allow(client).to receive(:workspaces).and_return([ workspace.merge("layoutYaml" => "tabs:\n  - panes: [agent]\n") ])
      allow(client).to receive(:update_layout).with(workspace: "app", layout: "").and_return("usingDefault" => true)
      allow(PaneyardPlugin::WorkspaceMatch).to receive(:repository_of).and_return([ "/code/app", "main" ])

      run_cli("layout-ui", input: "r\ns\n\n", context: { "focused_pane_cwd" => "/code/app" })

      expect(out.string).to include("Reset to the default layout.")
    end

    it "refuses `agent` or a taken name for another pane as soon as it is typed" do
      allow(client).to receive(:workspaces).and_return([ workspace ])
      allow(client).to receive(:update_layout).and_return("usingDefault" => false)
      allow(PaneyardPlugin::WorkspaceMatch).to receive(:repository_of).and_return([ "/code/app", "main" ])

      run_cli("layout-ui", input: "t\nhook\nagent\nt\nhook\ndiff\nhunk diff --watch\na\n2\ndiff\ns\n\n",
        context: { "focused_pane_cwd" => "/code/app" })

      expect(out.string).to include("`agent` is the agent's own pane", "There is already a pane named diff.")
      expect(client).to have_received(:update_layout).with(workspace: "app", layout: include("name: diff", "command: hunk diff --watch"))
    end

    it "rejects edited YAML whose tabs or panes the builder could not work on" do
      allow(client).to receive(:workspaces).and_return([ workspace ])
      allow(client).to receive(:update_layout)
      allow(PaneyardPlugin::WorkspaceMatch).to receive(:repository_of).and_return([ "/code/app", "main" ])
      editor = File.join(state, "editor")
      File.write(editor, "#!/bin/sh\nprintf 'tabs:\\n- just-a-string\\n' > \"$1\"\n")
      File.chmod(0o755, editor)

      status = run_cli("layout-ui", input: "y\na\nshell\n\n1\n\n\nq\n", context: { "focused_pane_cwd" => "/code/app" }) do |cli|
        cli.instance_variable_get(:@env)["VISUAL"] = editor
      end

      expect(status).to eq(0)
      expect(out.string).to include("YAML was not applied: tab 1 must be a mapping", "1.2 └─ shell [right of agent]")
    end

    it "keeps an unexpected error on screen instead of vanishing" do
      allow(client).to receive(:workspaces).and_raise(NoMethodError, "undefined method 'fetch'")

      status = run_cli("layout-ui", input: "\n", context: { "focused_pane_cwd" => "/code/app" })

      expect(status).to eq(1)
      expect(out.string).to include("unexpected error: NoMethodError", "Press Enter to close.")
    end

    it "explains when the pane is not registered" do
      allow(client).to receive(:workspaces).and_return([])
      allow(PaneyardPlugin::WorkspaceMatch).to receive(:repository_of).and_return([ "/code/other", "main" ])

      run_cli("layout-ui", input: "\n", context: { "focused_pane_cwd" => "/code/other" })

      expect(out.string).to include("not inside a registered Paneyard workspace")
    end
  end

  it "tells the operator when Paneyard had to move to another port" do
    allow(daemon).to receive(:ensure_running).and_return(PaneyardPlugin::Daemon::Result.new(
      outcome: :started, pid: 1, port: 7999, url: "http://127.0.0.1:7999", previous_port: 7001
    ))

    run_cli("start")

    expect(herdr_calls.first).to include("Paneyard moved to port 7999")
  end
end

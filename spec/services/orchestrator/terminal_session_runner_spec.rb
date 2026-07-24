require "rails_helper"

RSpec.describe Orchestrator::TerminalSessionRunner do
  it "starts a pty-backed process, streams echoed input into the scrollback log, and reconciles its exit" do
    with_fake_terminal_clis do
      session = create_session

      described_class.start(session)

      expect(session.status).to eq("running")
      expect(session.pid).to be_present
      expect(session.cli_session_id).to be_present

      described_class.write_input(session, "hello\n")
      wait_until { File.exist?(session.log_path) && File.read(session.log_path).include?("echo:hello") }

      Process.kill("TERM", -session.process_group_id)
      wait_until { described_class.reconcile!(session.reload).status == "exited" }

      expect(session.reload.status).to eq("exited")
    end
  end

  it "does not re-register a pty reader for a session already live in this process" do
    with_fake_terminal_clis do
      session = create_session
      described_class.start(session)

      expect(described_class.live?(session)).to be(true)

      described_class.stop(session, reason: "test cleanup")
      expect(described_class.live?(session)).to be(false)
      expect(session.reload.status).to eq("exited")
    end
  end

  it "resume respawns with the persisted cli_session_id and keeps prior scrollback" do
    with_fake_terminal_clis do
      session = create_session
      described_class.start(session)
      described_class.write_input(session, "first\n")
      wait_until { File.read(session.log_path).to_s.include?("echo:first") }
      original_cli_session_id = session.cli_session_id

      described_class.stop(session, reason: "restart for resume test")

      described_class.resume(session)
      expect(session.reload.cli_session_id).to eq(original_cli_session_id)
      expect(File.read(session.log_path)).to include("echo:first")

      described_class.write_input(session, "second\n")
      wait_until { File.read(session.log_path).to_s.include?("echo:second") }

      described_class.stop(session, reason: "test cleanup")
    end
  end

  it "builds a read-only claude tool profile with no Edit/Write" do
    session = create_session(launcher_variant: "claude")
    policy = Orchestrator::WorkerExecutionPolicy.new(
      root_dir: Pathname(session.workspace.root_path), mode: nil, write_scope: "source_protected", allowed_paths: []
    )

    args = described_class.claude_args(
      policy:, root_dir: session.workspace.root_path, mcp_config_path: "/tmp/mcp.json",
      settings_path: "/tmp/settings.json", cli_session_id: "abc", resume: false
    )

    expect(policy.claude_tools).not_to include("Edit")
    expect(policy.claude_tools).not_to include("Write")
    expect(args).to include("--session-id", "abc")
    expect(args).not_to include("--resume")
  end

  it "passes --resume instead of --session-id when resuming" do
    args = described_class.claude_args(
      policy: Orchestrator::WorkerExecutionPolicy.new(
        root_dir: Pathname(Dir.mktmpdir), mode: nil, write_scope: "source_protected", allowed_paths: []
      ),
      root_dir: "/tmp", mcp_config_path: "/tmp/mcp.json", settings_path: "/tmp/settings.json",
      cli_session_id: "abc", resume: true
    )

    expect(args).to include("--resume", "abc")
    expect(args).not_to include("--session-id")
  end

  def create_session(launcher_variant: "claude")
    root = Dir.mktmpdir("terminal-session-runner")
    workspace = Workspace.create!(name: "terminal-session-runner-#{SecureRandom.hex(4)}", root_path: root)
    workspace.create_terminal_session!(launcher_variant:, status: "starting")
  end
end

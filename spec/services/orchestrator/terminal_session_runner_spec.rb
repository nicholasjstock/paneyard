require "rails_helper"

RSpec.describe Orchestrator::TerminalSessionRunner do
  it "starts a pty-backed shell, streams command output into the scrollback log, and reconciles its exit" do
    session = create_session

    described_class.start(session)

    expect(session.status).to eq("running")
    expect(session.pid).to be_present

    described_class.write_input(session, "echo hello-from-shell\n")
    wait_until { File.exist?(session.log_path) && File.read(session.log_path).include?("hello-from-shell") }

    Process.kill("TERM", -session.process_group_id)
    wait_until { described_class.reconcile!(session.reload).status == "exited" }

    expect(session.reload.status).to eq("exited")
  end

  it "does not re-register a pty reader for a session already live in this process" do
    session = create_session
    described_class.start(session)

    expect(described_class.live?(session)).to be(true)

    described_class.stop(session, reason: "test cleanup")
    expect(described_class.live?(session)).to be(false)
    expect(session.reload.status).to eq("exited")
  end

  it "resume respawns a fresh shell and keeps prior scrollback" do
    session = create_session
    described_class.start(session)
    described_class.write_input(session, "echo first-marker\n")
    wait_until { File.read(session.log_path).to_s.include?("first-marker") }

    described_class.stop(session, reason: "restart for resume test")

    described_class.resume(session)
    expect(File.read(session.log_path)).to include("first-marker")

    described_class.write_input(session, "echo second-marker\n")
    wait_until { File.read(session.log_path).to_s.include?("second-marker") }

    described_class.stop(session, reason: "test cleanup")
  end

  it "#start truncates the scrollback log while #resume appends to it" do
    session = create_session
    described_class.start(session)
    described_class.write_input(session, "echo before-restart\n")
    wait_until { File.read(session.log_path).to_s.include?("before-restart") }
    described_class.stop(session, reason: "test cleanup")

    described_class.start(session.reload)

    expect(File.read(session.log_path)).not_to include("before-restart")
  end

  def create_session
    root = Dir.mktmpdir("terminal-session-runner")
    workspace = Workspace.create!(name: "terminal-session-runner-#{SecureRandom.hex(4)}", root_path: root)
    workspace.create_terminal_session!(status: "starting")
  end
end

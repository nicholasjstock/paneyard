require "rails_helper"

RSpec.describe TerminalSessionChannel, type: :channel do
  it "streams replayed scrollback and resumes a not-live session on subscribe" do
    session = create_session

    allow(Orchestrator::TerminalSessionRunner).to receive(:live?).with(session).and_return(false)
    allow(Orchestrator::TerminalSessionRunner).to receive(:replay).with(session).and_return("prior scrollback")
    allow(Orchestrator::TerminalSessionRunner).to receive(:resume).with(session)

    subscribe(id: session.id)

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from(Orchestrator::TerminalSessionRunner.stream_name(session.id))
    expect(transmissions.last).to eq("type" => "replay", "data" => "prior scrollback")
    expect(Orchestrator::TerminalSessionRunner).to have_received(:resume).with(session)
  end

  it "does not resume when the session is already live in this process" do
    session = create_session
    allow(Orchestrator::TerminalSessionRunner).to receive(:live?).with(session).and_return(true)
    allow(Orchestrator::TerminalSessionRunner).to receive(:replay).with(session).and_return("")
    allow(Orchestrator::TerminalSessionRunner).to receive(:resume)

    subscribe(id: session.id)

    expect(Orchestrator::TerminalSessionRunner).not_to have_received(:resume)
  end

  it "rejects the subscription for an unknown session id" do
    subscribe(id: -1)

    expect(subscription).to be_rejected
  end

  it "forwards input and resize messages to the runner" do
    session = create_session
    allow(Orchestrator::TerminalSessionRunner).to receive(:live?).with(session).and_return(true)
    allow(Orchestrator::TerminalSessionRunner).to receive(:replay).with(session).and_return("")
    subscribe(id: session.id)

    expect(Orchestrator::TerminalSessionRunner).to receive(:write_input).with(session, "ls\n")
    perform :receive, "type" => "input", "data" => "ls\n"

    expect(Orchestrator::TerminalSessionRunner).to receive(:resize).with(session, cols: 80, rows: 24)
    perform :receive, "type" => "resize", "cols" => 80, "rows" => 24
  end

  def create_session
    workspace = Workspace.create!(name: "terminal-channel-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    workspace.create_terminal_session!(status: "starting")
  end
end

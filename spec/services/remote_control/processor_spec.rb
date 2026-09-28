require "rails_helper"

# The platform-neutral core against FakeRemoteControlAdapter, with nothing
# stubbed: runs and sessions are database rows whose herdr panes do not exist
# (specs have no herdr), which is enough for everything decided before a pane
# is touched -- who is answered, which run a message means, what a platform
# without editing or tappable commands gets. What a session actually shows or
# receives is covered through the real Telegram adapter, fake Telegram and
# fake herdr in spec/integration/telegram_remote_control_spec.rb.
RSpec.describe RemoteControl::Processor do
  let(:adapter) { FakeRemoteControlAdapter.new(allowed: [ "42", "43" ]) }
  let(:workspace) { create_workspace(prefix: "rc") }

  after { FileUtils.remove_entry(workspace.root_path) if Dir.exist?(workspace.root_path) }

  def message(text, from: 42, reply_to: nil)
    RemoteControl::Message.new(chat_id: from, user_id: from, text:, reply_to_text: reply_to)
  end

  def process(text, via: adapter, **options) = described_class.call(via, message(text, **options))
  def replies = adapter.texts

  def live_run(suffix, worktree:, agent_status: "working", status: "running")
    run = create_run(workspace:, run_id: "run-20260927-000000-#{suffix}", worktree_name: worktree, status:)
    _, session = create_run_and_session(run:, agent_status:)
    [ run, session ]
  end

  # With no herdr to read, a command that got as far as the pane says so --
  # which shows which run it resolved to.
  def unreadable(run) = "#{RemoteControl::Views.header(run)}\nherdr could not read this session's pane."

  it "ignores users who are not on the adapter's allow-list" do
    live_run("aaaa", worktree: "layouts-aaaa")

    process("/panes", from: 7)

    expect(adapter.sent).to be_empty
  end

  describe "/panes and /idle" do
    it "lists live sessions with the adapter's command links, newest first" do
      live_run("aaaa", worktree: "layouts-aaaa", agent_status: "working")
      idle_run, idle_session = live_run("bbbb", worktree: "fix-tax-bbbb", agent_status: "idle", status: "awaiting_review")
      idle_run.checkpoints.create!(run_session: idle_session, outcome: "done", summary: "Shipped.")
      create_run(workspace:, run_id: "run-20260927-000000-cccc", worktree_name: "done-cccc", status: "completed")

      process("/panes")

      expect(replies.join).to include("2 live sessions", "aaaa · #{workspace.name} · working", "/pane_aaaa /screen_aaaa")
      expect(replies.join).to include("bbbb · #{workspace.name} · idle (idle)", "last report: done")
      expect(replies.join).not_to include("cccc")
    end

    it "lists only the sessions waiting on the operator" do
      live_run("aaaa", worktree: "layouts-aaaa", agent_status: "working")
      live_run("bbbb", worktree: "blocked-bbbb", agent_status: "blocked")
      live_run("dddd", worktree: "reported-dddd", agent_status: nil, status: "awaiting_review")
      live_run("eeee", worktree: "busy-eeee", agent_status: "working", status: "awaiting_review")

      process("/idle")

      expect(replies.join).to include("2 idle sessions", "bbbb", "dddd")
      expect(replies.join).not_to include("aaaa", "eeee")
    end

    it "writes command links the way the adapter says, e.g. where they are not tappable" do
      live_run("aaaa", worktree: "layouts-aaaa")
      plain = Class.new(FakeRemoteControlAdapter) { def command_link(command, ref) = "/#{command} #{ref}" }.new

      process("/panes", via: plain)

      expect(plain.texts.join).to include("/pane aaaa /screen aaaa")
    end
  end

  describe "naming a run" do
    it "takes the four-character ref, a worktree-name prefix, or the full run id, in either command form" do
      run, = live_run("aaaa", worktree: "layouts-aaaa")

      [ "/screen_aaaa", "/screen aaaa", "/screen layouts", "/screen #{run.run_id}" ].each { |text| process(text) }

      expect(replies).to eq([ unreadable(run) ] * 4)
    end

    it "treats an all-digit ref as a run, not a line count" do
      run, = live_run("1234", worktree: "digits-1234")

      process("/screen_1234")
      process("/screen 1234")

      expect(replies).to eq([ unreadable(run) ] * 2)
    end

    it "asks which run when a reference is ambiguous, or matches none" do
      live_run("aaaa", worktree: "layouts-aaaa")
      live_run("bbbb", worktree: "layouts-bbbb")

      process("/pane layouts")
      process("/pane zzzz")

      expect(replies.first).to include("matches more than one run", "aaaa · layouts-aaaa", "bbbb · layouts-bbbb")
      expect(replies.last).to eq("No live run matches \"zzzz\". Try /panes.")
    end

    it "means the run the chat last named when none is given, per chat and per adapter" do
      run, = live_run("aaaa", worktree: "layouts-aaaa")
      other = Class.new(FakeRemoteControlAdapter) { def name = "other" }.new

      process("/screen aaaa")
      process("/screen 80")
      process("/screen 80", from: 43)
      process("/screen 80", via: other)

      expect(replies).to eq([ unreadable(run), unreadable(run), "Which run? Try /panes." ])
      expect(other.texts).to eq([ "Which run? Try /panes." ])
    end

    it "does not send to a run whose session has since ended" do
      run, session = live_run("aaaa", worktree: "layouts-aaaa")
      process("/screen aaaa")
      session.update!(status: "done", ended_at: Time.current)

      process("more work")

      expect(replies.last).to eq("No live run matches #{run.run_id.inspect}. Try /panes.")
    end
  end

  describe "talking to a run" do
    it "explains what to do with plain text when no run is chosen" do
      process("hello")
      process("hello", reply_to: "No live run matches \"zzzz\". Try /panes.")

      expect(replies).to all(start_with("Pick a run first"))
    end

    it "explains /send usage" do
      process("/send")
      process("/send aaaa")

      expect(replies).to eq([ described_class::SEND_USAGE ] * 2)
    end
  end

  it "shows the newest recap even after the session is closed, falling back to text if Markdown is refused" do
    run, session = live_run("aaaa", worktree: "layouts-aaaa")
    run.checkpoints.create!(run_session: session, outcome: "blocked", summary: "old")
    run.checkpoints.create!(run_session: session, outcome: "done", summary: "| a |")
    session.update!(ended_at: Time.current, status: "done")
    adapter.markdown_error = "rendering refused"

    process("/report aaaa")

    expect(replies).to match([ start_with("run aaaa · layouts-aaaa\nRecap: done"), "| a |" ])
  end

  it "answers anything else with the help" do
    process("/start")

    expect(replies).to eq([ RemoteControl::Commands::HELP ])
  end

  describe "on a platform that cannot edit messages", :fake_herdr, type: :request do
    include_context "launched runs"

    it "sends /pane once instead of keeping it live" do
      plain = FakeRemoteControlAdapter.new(edits: false)
      run = queue_and_launch("Busy [fake-agent: working]")

      process("/pane #{run.run_id}", via: plain)

      expect(plain.panes.map(&:first)).to eq([ "#{RemoteControl::Views.header(run)}\nNo report yet" ])
      expect(StreamPaneJob).not_to have_been_enqueued
    end
  end
end

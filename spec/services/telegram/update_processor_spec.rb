require "rails_helper"

RSpec.describe Telegram::UpdateProcessor do
  let(:client) { instance_double(Telegram::Client, send_rich_message: { "message_id" => 2 }) }
  let(:sent_texts) { [] }
  let(:workspace) { create_workspace(prefix: "tg") }

  before do
    allow(Telegram::Client).to receive(:new).and_return(client)
    allow(client).to receive(:send_message) do |**args|
      sent_texts << args[:text]
      { "message_id" => 77 }
    end
    # What herdr says the agent is doing right now; nil unless a spec says.
    allow(Orchestrator::Runner::Herdr).to receive(:agent_get).and_return({})
    allow(Telegram::Configuration).to receive(:authorized_user?).and_return(false)
    allow(Telegram::Configuration).to receive(:authorized_user?).with("42").and_return(true)
  end

  after { FileUtils.remove_entry(workspace.root_path) if Dir.exist?(workspace.root_path) }

  def message(text, from: 42, chat: from, type: "private", reply_to: nil)
    msg = { "chat" => { "id" => chat, "type" => type }, "from" => { "id" => from }, "text" => text }
    msg["reply_to_message"] = { "text" => reply_to } if reply_to
    { "message" => msg }
  end

  def live_run(suffix, worktree:, agent_status: "working", status: "running")
    run = create_run(workspace:, run_id: "run-20260927-000000-#{suffix}", worktree_name: worktree, status:)
    _, session = create_run_and_session(run:, agent_status:)
    [ run, session ]
  end

  describe "authorization" do
    it "ignores users who are not on the allow-list" do
      described_class.call(message("/panes", from: 7))

      expect(client).not_to have_received(:send_message)
    end

    it "ignores an allowed user writing from a group chat" do
      described_class.call(message("/panes", chat: -100, type: "group"))

      expect(client).not_to have_received(:send_message)
    end

    it "ignores bots" do
      update = message("/panes")
      update["message"]["from"]["is_bot"] = true

      described_class.call(update)

      expect(client).not_to have_received(:send_message)
    end
  end

  describe "/panes and /idle" do
    it "lists every live session with tappable pane and report commands" do
      live_run("aaaa", worktree: "layouts-aaaa", agent_status: "working")
      idle_run, idle_session = live_run("bbbb", worktree: "fix-tax-bbbb", agent_status: "idle", status: "awaiting_review")
      idle_run.checkpoints.create!(run_session: idle_session, outcome: "done", summary: "Shipped.")
      create_run(workspace:, run_id: "run-20260927-000000-cccc", worktree_name: "done-cccc", status: "completed")

      described_class.call(message("/panes"))

      text = sent_texts.join("\n")
      expect(text).to include("2 live sessions")
      expect(text).to include("aaaa · #{workspace.name} · working", "/pane_aaaa /screen_aaaa")
      expect(text).to include("bbbb · #{workspace.name} · idle (idle)", "last report: done")
      expect(text).not_to include("cccc")
    end

    it "lists only the sessions that are not working" do
      live_run("aaaa", worktree: "layouts-aaaa", agent_status: "working")
      live_run("bbbb", worktree: "blocked-bbbb", agent_status: "blocked")
      live_run("dddd", worktree: "reported-dddd", agent_status: nil, status: "awaiting_review")

      described_class.call(message("/idle"))

      text = sent_texts.join("\n")
      expect(text).to include("2 idle sessions", "bbbb", "dddd")
      expect(text).not_to include("aaaa")
    end

    it "treats a session that reported idle but has since been given more work as working" do
      live_run("aaaa", worktree: "busy-aaaa", agent_status: "working", status: "awaiting_review")

      described_class.call(message("/idle"))

      expect(sent_texts.join).to include("0 idle sessions")
    end
  end

  describe "/pane" do
    it "shows the latest recap when the session has reported and is not working again" do
      run, session = live_run("aaaa", worktree: "layouts-aaaa", agent_status: "idle")
      run.checkpoints.create!(run_session: session, outcome: "done", summary: "## Shipped\n\nAll green.")
      allow(Orchestrator::Runner::Herdr).to receive(:agent_get).with("w1:p1").and_return("agent_status" => "idle")
      allow(Orchestrator::RunSessionRunner).to receive(:snapshot)

      described_class.call(message("/pane_aaaa"))

      expect(sent_texts.first).to start_with("run aaaa · layouts-aaaa\nRecap: done")
      expect(sent_texts.first).to include("/screen_aaaa for the raw pane")
      expect(client).to have_received(:send_rich_message).with(chat_id: 42, markdown: "## Shipped\n\nAll green.")
      expect(Orchestrator::RunSessionRunner).not_to have_received(:snapshot)
      expect(StreamTelegramPaneJob).not_to have_been_enqueued
    end

    it "shows the live pane, and keeps it updating, when the session has not reported yet" do
      _run, session = live_run("aaaa", worktree: "layouts-aaaa")
      allow(Orchestrator::RunSessionRunner).to receive(:snapshot).and_return("thinking...\n")

      described_class.call(message("/pane aaaa"))

      expect(client).to have_received(:send_message).with(
        chat_id: 42, parse_mode: "HTML", text: "run aaaa · layouts-aaaa\nNo report yet · live for 3 min\n<pre>thinking...</pre>"
      )
      expect(StreamTelegramPaneJob).to have_been_enqueued.with(
        hash_including(chat_id: 42, message_id: 77, session_id: session.id, since_checkpoint_id: 0)
      )
    end

    it "shows the live pane rather than a stale recap when herdr says it is working again" do
      run, session = live_run("aaaa", worktree: "layouts-aaaa", agent_status: "idle")
      checkpoint = run.checkpoints.create!(run_session: session, outcome: "done", summary: "Old news.")
      allow(Orchestrator::Runner::Herdr).to receive(:agent_get).with("w1:p1").and_return("agent_status" => "working")
      allow(Orchestrator::RunSessionRunner).to receive(:snapshot).and_return("editing...")

      described_class.call(message("/pane aaaa"))

      expect(sent_texts.first).to include("Working again since its last report")
      expect(client).not_to have_received(:send_rich_message)
      expect(StreamTelegramPaneJob).to have_been_enqueued.with(hash_including(since_checkpoint_id: checkpoint.id))
    end
  end

  describe "/screen" do
    it "sends the newest lines of the pane once, HTML-escaped, from the tappable form" do
      _run, session = live_run("aaaa", worktree: "layouts-aaaa")
      allow(Orchestrator::RunSessionRunner).to receive(:snapshot).and_return("line 1\n<b>line 2</b>\n")

      described_class.call(message("/screen_aaaa 80"))

      expect(Orchestrator::RunSessionRunner).to have_received(:snapshot).with(session, lines: 80)
      expect(client).to have_received(:send_message).with(
        chat_id: 42, parse_mode: "HTML",
        text: "run aaaa · layouts-aaaa\nScreen · working\n<pre>line 1\n&lt;b&gt;line 2&lt;/b&gt;</pre>"
      )
      expect(StreamTelegramPaneJob).not_to have_been_enqueued
    end

    it "trims a long pane from the top so the newest lines fit one message" do
      live_run("aaaa", worktree: "layouts-aaaa")
      lines = (1..400).map { |i| "line #{i} #{'x' * 20}\n" }.join
      allow(Orchestrator::RunSessionRunner).to receive(:snapshot).and_return(lines)

      described_class.call(message("/screen aaaa"))

      expect(client).to have_received(:send_message) do |**args|
        expect(args[:text].length).to be <= Telegram::Client::MAX_MESSAGE_LENGTH
        expect(args[:text]).to include("line 400")
        expect(args[:text]).not_to include("line 1 ")
      end
    end

    it "resolves a run by a prefix of its worktree name" do
      _run, session = live_run("aaaa", worktree: "layouts-aaaa")
      allow(Orchestrator::RunSessionRunner).to receive(:snapshot).and_return("ok")

      described_class.call(message("/screen layouts"))

      expect(Orchestrator::RunSessionRunner).to have_received(:snapshot).with(session, lines: 40)
    end

    it "asks which run when a reference is ambiguous" do
      live_run("aaaa", worktree: "layouts-aaaa")
      live_run("bbbb", worktree: "layouts-bbbb")
      allow(Orchestrator::RunSessionRunner).to receive(:snapshot)

      described_class.call(message("/pane layouts"))

      expect(Orchestrator::RunSessionRunner).not_to have_received(:snapshot)
      expect(sent_texts.join).to include("matches more than one run", "aaaa · layouts-aaaa", "bbbb · layouts-bbbb")
    end

    it "says so when no live run matches" do
      described_class.call(message("/pane zzzz"))

      expect(sent_texts.join).to include("No live run matches \"zzzz\"")
    end
  end

  describe "/report" do
    it "sends the newest checkpoint as rich Markdown under a run header" do
      run, session = live_run("aaaa", worktree: "layouts-aaaa")
      run.checkpoints.create!(run_session: session, outcome: "blocked", summary: "old")
      run.checkpoints.create!(run_session: session, outcome: "done", summary: "## Done\n\nAll green.")

      described_class.call(message("/report_aaaa"))

      expect(sent_texts.first).to start_with("run aaaa · layouts-aaaa\nRecap: done")
      expect(client).to have_received(:send_rich_message).with(chat_id: 42, markdown: "## Done\n\nAll green.")
    end

    it "still works once the session has been closed" do
      run, session = live_run("aaaa", worktree: "layouts-aaaa")
      run.checkpoints.create!(run_session: session, outcome: "done", summary: "Finished.")
      session.update!(ended_at: Time.current, status: "done")
      run.update!(status: "completed")

      described_class.call(message("/report aaaa"))

      expect(client).to have_received(:send_rich_message).with(chat_id: 42, markdown: "Finished.")
    end

    it "falls back to plain text when rich rendering is refused" do
      run, session = live_run("aaaa", worktree: "layouts-aaaa")
      run.checkpoints.create!(run_session: session, outcome: "done", summary: "| a |")
      allow(client).to receive(:send_rich_message).and_raise("Telegram sendRichMessage failed")

      described_class.call(message("/report aaaa"))

      expect(client).to have_received(:send_message).with(chat_id: 42, text: "| a |")
    end
  end

  describe "sending instructions" do
    it "types /send text into the session's pane" do
      _run, session = live_run("aaaa", worktree: "layouts-aaaa")
      allow(Orchestrator::RunSessionRunner).to receive(:prompt!)

      described_class.call(message("/send aaaa go ahead with the migration"))

      expect(Orchestrator::RunSessionRunner).to have_received(:prompt!).with(session, "go ahead with the migration")
      expect(sent_texts.last).to eq("run aaaa · layouts-aaaa\nSent.")
    end

    it "routes a reply to a message about a run into that run's session" do
      _run, session = live_run("aaaa", worktree: "layouts-aaaa")
      allow(Orchestrator::RunSessionRunner).to receive(:prompt!)

      described_class.call(message("yes, use the second option", reply_to: "run aaaa · layouts-aaaa\n<pre>...</pre>"))

      expect(Orchestrator::RunSessionRunner).to have_received(:prompt!).with(session, "yes, use the second option")
    end

    it "does not treat a reply to some other message as addressed to a run" do
      allow(Orchestrator::RunSessionRunner).to receive(:prompt!)

      described_class.call(message("hello", reply_to: "No live run matches \"zzzz\". Try /panes."))

      expect(Orchestrator::RunSessionRunner).not_to have_received(:prompt!)
      expect(sent_texts.join).to include("/send <run> <text>")
    end

    it "reports why a send failed instead of raising" do
      live_run("aaaa", worktree: "layouts-aaaa")
      allow(Orchestrator::RunSessionRunner).to receive(:prompt!).and_raise(Orchestrator::Runner::Error, "no such pane")

      described_class.call(message("/send aaaa hi"))

      expect(sent_texts.last).to eq("run aaaa · layouts-aaaa\nNot sent: no such pane")
    end

    it "explains usage when /send has no text" do
      described_class.call(message("/send aaaa"))

      expect(sent_texts.last).to eq("Usage: /send <run> <text>")
    end
  end

  it "answers anything else with the command list" do
    described_class.call(message("/start"))

    expect(sent_texts.last).to include("/panes", "/idle", "/pane <run>", "/screen <run>", "/report <run>", "/send <run> <text>")
  end
end

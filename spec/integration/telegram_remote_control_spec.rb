require "rails_helper"

# Remote control from the operator's phone, end to end, with nothing stubbed
# in between: the operator's message goes into a fake Telegram
# (FakeTelegram::Server, real HTTP), PollTelegramUpdatesJob fetches it through
# the real Telegram adapter and client, RemoteControl::Processor acts on real
# runs launched through the fake herdr (real agent processes), and what the
# bot answers is read back from the fake Telegram as the phone would show it:
# plain text after HTML parsing, within Telegram's 4096-character cap.
RSpec.describe "Telegram remote control", :fake_herdr, :fake_telegram, type: :request do
  include_context "launched runs"

  def operator(text, **options)
    fake_telegram.say(text, **options)
    PollTelegramUpdatesJob.perform_now
  end

  def bot_texts = fake_telegram.texts
  def ref(run) = run.run_id.split("-").last
  def pane_of(run) = fake_herdr.pane(run.live_session.herdr_pane_id)

  # What herdr says the agent is doing -- the fake agent is "working" on its
  # task prompt for a moment after launch.
  def wait_until_agent(run, status)
    wait_for { Orchestrator::Runner.for(run.workspace).agent_state(run.live_session.herdr_pane_id)&.dig("agent_status") == status }
  end

  # One tick of the live /pane message's StreamPaneJob, as the queue would run
  # it -- returns whether it scheduled another.
  def tick_stream(**overrides)
    job = enqueued_jobs.reverse.find { |enqueued| enqueued["job_class"] == "StreamPaneJob" } or raise "no stream scheduled"
    clear_enqueued_jobs
    StreamPaneJob.perform_now(**ActiveJob::Arguments.deserialize(job["arguments"]).first.merge(overrides))
    enqueued_jobs.any? { |enqueued| enqueued["job_class"] == "StreamPaneJob" }
  end

  it "lists live sessions, shows one's recap, and types into it" do
    first = queue_and_launch("Fix the layout")
    second = queue_and_launch("Add billing")
    report(second, "done", "## Shipped\n\nAll green.")
    wait_until_agent(second, "idle")

    operator("/panes")
    expect(bot_texts.last).to include("2 live sessions", "/pane_#{ref(first)} /screen_#{ref(first)}", "last report: done")

    operator("/pane_#{ref(second)}")
    recap = fake_telegram.messages.last(2)
    expect(recap.first.text).to start_with("run #{ref(second)} · #{second.worktree_name}\nRecap: done")
    expect(recap.last).to have_attributes(kind: :rich, raw: "## Shipped\n\nAll green.")

    # It is now the chat's run: plain text goes to it, and says where it went.
    operator("please also add a test")
    expect(bot_texts.last).to eq("run #{ref(second)} · #{second.worktree_name}\nSent.")
    expect(fake_herdr.requests_for("agent.prompt").last).to include("target" => second.live_session.herdr_pane_id, "text" => "please also add a test")
    wait_for { pane_of(second)[:transcript].include?("received a 22-character prompt") }

    operator("/screen")
    expect(bot_texts.last).to start_with("run #{ref(second)} · #{second.worktree_name}\nScreen ·")
    expect(bot_texts.last).to include("received a 22-character prompt")
  end

  it "sends a reply to the run the replied-to message is about, whichever run the chat is on" do
    first = queue_and_launch("First")
    second = queue_and_launch("Second")
    operator("/send #{ref(first)} hello first")
    about_first = fake_telegram.messages.last
    operator("/pane_#{ref(second)}")

    operator("and one more thing", reply_to: about_first)

    expect(fake_herdr.requests_for("agent.prompt").last).to include("target" => first.live_session.herdr_pane_id, "text" => "and one more thing")
  end

  it "keeps a working session's pane live, then posts its recap when it reports" do
    run = queue_and_launch("Keep busy [fake-agent: working]")
    wait_until_agent(run, "working")

    operator("/pane_#{ref(run)}")
    live = fake_telegram.messages.last
    expect(live.text).to start_with("run #{ref(run)} · #{run.worktree_name}\nNo report yet · live for 3 min")

    expect(tick_stream).to be(true)
    expect(live.edits).to eq(0) # nothing changed on screen, nothing to edit

    pane_of(run)[:transcript] << "step 2 of 3\n"
    tick_stream
    expect(live.edits).to eq(1)
    expect(live.text).to include("Live · ", "step 2 of 3")

    report(run, "done", "Finished all three steps.")
    expect(tick_stream).to be(false)
    expect(live.text).to include("Reported idle (done). Recap below.")
    expect(fake_telegram.messages.last).to have_attributes(kind: :rich, raw: "Finished all three steps.")
  end

  it "shows the live pane rather than a stale recap when the session is working again" do
    run = queue_and_launch("Busy again [fake-agent: working]")
    report(run, "done", "Old news.")

    operator("/pane_#{ref(run)}")

    expect(bot_texts.last).to include("Working again since its last report · live for 3 min")
    expect(fake_telegram.messages.map(&:kind)).not_to include(:rich)
  end

  it "stops the live pane when its time is up, or when the session ends" do
    run = queue_and_launch("Watch me [fake-agent: working]")
    operator("/pane_#{ref(run)}")
    live = fake_telegram.messages.last

    expect(tick_stream(until_time: 1.second.ago.iso8601)).to be(false)
    expect(live.text).to include("Stopped updating. /pane_#{ref(run)} to watch again.")

    operator("/pane_#{ref(run)}")
    again = fake_telegram.messages.last
    post close_session_workspace_run_path(workspace, run)
    expect(tick_stream).to be(false)
    expect(again.text).to include("Session ended.")
  end

  it "splits a long screen over several messages, oldest first, each within Telegram's cap" do
    run = queue_and_launch("Chatty")
    lines = (1..250).map { |i| "line #{i} #{'x' * 40}\n" }
    pane_of(run)[:transcript] << lines.join

    operator("/screen_#{ref(run)} 1000")

    pages = fake_telegram.messages.select { |message| message.text.include?("Screen ·") }
    expect(pages.size).to be_between(3, 5), bot_texts.inspect[0, 600]
    expect(pages.map { |page| page.text[%r{Screen · \w+ · (\d)/\d}, 1].to_i }).to eq((1..pages.size).to_a)
    expect(pages.last.text).to end_with(lines.last.chomp)
    shown = pages.flat_map { |page| page.text.lines.drop(2).map(&:chomp) }
    expect(shown.last(250)).to eq(lines.map(&:chomp))
    expect(pages.first.text).not_to include("did not fit")
    expect(bot_texts.join).not_to include("Something went wrong")
  end

  it "drops the oldest lines past five messages, and says so" do
    run = queue_and_launch("Very chatty")
    pane_of(run)[:transcript] << (1..600).map { |i| "line #{i} #{'x' * 40}\n" }.join

    operator("/screen_#{ref(run)} 1000")

    pages = fake_telegram.messages
    expect(pages.size).to eq(RemoteControl::Processor::MAX_SCREEN_MESSAGES)
    expect(pages.first.text).to match(%r{Screen · \w+ · 1/5 · \d+ older lines did not fit})
    expect(pages.last.text).to end_with("line 600 #{'x' * 40}")
  end

  it "keeps the live pane going when Telegram refuses an edit, and stops it if Telegram is switched off" do
    run = queue_and_launch("Refused [fake-agent: working]")
    operator("/pane_#{ref(run)}")
    pane_of(run)[:transcript] << "changed\n"

    expect(tick_stream(message_id: 999_999)).to be(true) # no such message: Telegram answers 400

    ENV["TELEGRAM_BOT_TOKEN"] = ""
    expect(tick_stream).to be(false)
  end

  it "shows pane text verbatim, never as markup" do
    run = queue_and_launch("Markup")
    pane_of(run)[:transcript] << "<b>not bold</b> & <i>co</i>\n"

    operator("/screen_#{ref(run)} 5")

    expect(bot_texts.last).to include("<b>not bold</b> & <i>co</i>")
  end

  it "still gives the recap once the session is closed" do
    run = queue_and_launch("Close me")
    report(run, "done", "Closed out.")
    post close_session_workspace_run_path(workspace, run)

    operator("/report #{ref(run)}")

    expect(fake_telegram.messages.last).to have_attributes(kind: :rich, raw: "Closed out.")
  end

  it "answers only the allow-listed operator, and only in their private chat" do
    queue_and_launch("Secret")

    operator("/panes", from: 7)
    operator("/panes", chat_id: -100, chat_type: "group")
    operator("/panes", is_bot: true)

    expect(fake_telegram.messages).to be_empty
    expect(TelegramUpdateCursor.for_bot.last_update_id).to eq(3)
  end

  it "publishes the command menu from the same list as the help" do
    operator("/help")

    expect(fake_telegram.commands.map { |command| command["command"] }).to eq(RemoteControl::Commands::LIST.map(&:first))
    expect(bot_texts.last).to eq(RemoteControl::Commands::HELP.strip)
  end
end

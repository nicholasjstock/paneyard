require "rails_helper"

RSpec.describe StreamTelegramPaneJob do
  let(:client) { instance_double(Telegram::Client, edit_message_text: {}, send_message: {}, send_rich_message: {}) }
  let(:run) { create_run(run_id: "run-20260927-000000-aaaa", worktree_name: "layouts-aaaa") }
  let(:session) { create_run_and_session(run:, agent_status: "working").last }

  before do
    allow(Telegram::Client).to receive(:new).and_return(client)
    allow(Orchestrator::RunSessionRunner).to receive(:snapshot).and_return("step 2\n")
  end

  after { FileUtils.remove_entry(run.workspace.root_path) if Dir.exist?(run.workspace.root_path) }

  def perform(**overrides)
    described_class.perform_now(
      chat_id: 42, message_id: 77, session_id: session.id, since_checkpoint_id: 0,
      until_time: 2.minutes.from_now.iso8601, **overrides
    )
  end

  def edited_text
    text = nil
    expect(client).to have_received(:edit_message_text) { |**args| text = args[:text] }
    text
  end

  it "edits the message with the fresh pane and schedules the next tick" do
    perform(last_digest: "stale")

    expect(edited_text).to match(%r{\Arun aaaa · layouts-aaaa\nLive · working · updated \d\d:\d\d:\d\d\n<pre>step 2</pre>\z})
    expect(described_class).to have_been_enqueued.with(
      hash_including(message_id: 77, last_digest: Digest::SHA256.hexdigest("step 2\n"))
    )
  end

  it "does not edit when the pane has not changed, but keeps watching" do
    perform(last_digest: Digest::SHA256.hexdigest("step 2\n"))

    expect(client).not_to have_received(:edit_message_text)
    expect(described_class).to have_been_enqueued
  end

  it "stops and follows with the recap once the session reports idle" do
    run.checkpoints.create!(run_session: session, outcome: "done", summary: "All done.")

    perform

    expect(edited_text).to include("Reported idle (done). Recap below.")
    expect(client).to have_received(:send_message).with(chat_id: 42, text: a_string_starting_with("run aaaa · layouts-aaaa\nRecap: done"))
    expect(client).to have_received(:send_rich_message).with(chat_id: 42, markdown: "All done.")
    expect(described_class).not_to have_been_enqueued
  end

  it "ignores a report the operator had already seen when the stream started" do
    earlier = run.checkpoints.create!(run_session: session, outcome: "done", summary: "Earlier.")

    perform(since_checkpoint_id: earlier.id)

    expect(client).not_to have_received(:send_rich_message)
    expect(described_class).to have_been_enqueued
  end

  it "stops when the session has ended" do
    session.update!(ended_at: Time.current, status: "done")

    perform

    expect(edited_text).to include("Session ended.")
    expect(described_class).not_to have_been_enqueued
  end

  it "stops when its time is up, and says how to watch again" do
    perform(until_time: 1.second.ago.iso8601)

    expect(edited_text).to include("Stopped updating. /pane_aaaa to watch again.")
    expect(described_class).not_to have_been_enqueued
  end

  it "keeps going when Telegram refuses an edit" do
    allow(client).to receive(:edit_message_text).and_raise("Telegram editMessageText failed: message to edit not found")

    expect { perform }.not_to raise_error
    expect(described_class).to have_been_enqueued
  end
end

require "rails_helper"

# The poller's happy path is spec/integration/telegram_remote_control_spec.rb.
# This is what can only be reached by making the processor itself blow up.
RSpec.describe RemoteControl::Adapters::Telegram::Poller, :fake_telegram do
  before { allow(RemoteControl::Processor).to receive(:call).and_raise(StandardError, "kaboom") }

  it "advances past an update that fails instead of retrying it forever, and tells the operator" do
    fake_telegram.say("boom")
    fake_telegram.say("fine")

    PollTelegramUpdatesJob.perform_now

    expect(RemoteControl::Processor).to have_received(:call).twice
    expect(TelegramUpdateCursor.for_bot.last_update_id).to eq(2)
    expect(fake_telegram.texts).to eq([ "Something went wrong handling that: kaboom" ] * 2)
  end

  it "tells a stranger nothing" do
    fake_telegram.say("boom", from: 7)

    PollTelegramUpdatesJob.perform_now

    expect(fake_telegram.messages).to be_empty
    expect(TelegramUpdateCursor.for_bot.last_update_id).to eq(1)
  end

  it "does not call Telegram at all until the bot has an allow-list" do
    ENV["TELEGRAM_ALLOWED_USER_IDS"] = ""
    fake_telegram.say("/panes")

    PollTelegramUpdatesJob.perform_now

    expect(fake_telegram.requests).to be_empty
  end
end

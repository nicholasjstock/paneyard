require "rails_helper"

RSpec.describe PollTelegramUpdatesJob do
  let(:client) { instance_double(Telegram::Client) }

  before do
    allow(Telegram::Configuration).to receive(:polling_configured?).and_return(true)
    allow(Telegram::Client).to receive(:new).and_return(client)
  end

  it "processes each update once and advances the durable polling cursor" do
    allow(client).to receive(:get_updates).with(offset: 0).and_return([
      { "update_id" => 2, "message" => { "text" => "second" } },
      { "update_id" => 1, "message" => { "text" => "first" } }
    ])
    expect(Telegram::UpdateProcessor).to receive(:call).with(hash_including("update_id" => 1)).ordered
    expect(Telegram::UpdateProcessor).to receive(:call).with(hash_including("update_id" => 2)).ordered

    described_class.perform_now

    expect(TelegramUpdateCursor.for_bot.last_update_id).to eq(2)
  end

  it "does not call Telegram until the bot is configured" do
    allow(Telegram::Configuration).to receive(:polling_configured?).and_return(false)

    described_class.perform_now

    expect(Telegram::Client).not_to have_received(:new)
  end
end

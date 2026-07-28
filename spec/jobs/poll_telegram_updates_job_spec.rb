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

  it "advances the cursor past a failing update instead of retrying it forever" do
    allow(client).to receive(:get_updates).with(offset: 0).and_return([
      { "update_id" => 1, "message" => { "chat" => { "id" => 42 }, "text" => "boom" } },
      { "update_id" => 2, "message" => { "text" => "fine" } }
    ])
    allow(Telegram::UpdateProcessor).to receive(:call).with(hash_including("update_id" => 1)).and_raise(StandardError, "kaboom")
    allow(Telegram::UpdateProcessor).to receive(:call).with(hash_including("update_id" => 2))
    allow(client).to receive(:send_message)

    described_class.perform_now

    expect(TelegramUpdateCursor.for_bot.last_update_id).to eq(2)
    expect(Telegram::UpdateProcessor).to have_received(:call).with(hash_including("update_id" => 2))
  end

  it "best-effort notifies the originating chat when an update fails" do
    allow(client).to receive(:get_updates).with(offset: 0).and_return([
      { "update_id" => 1, "message" => { "chat" => { "id" => 42 }, "text" => "boom" } }
    ])
    allow(Telegram::UpdateProcessor).to receive(:call).and_raise(StandardError, "kaboom")
    allow(client).to receive(:send_message)

    described_class.perform_now

    expect(client).to have_received(:send_message).with(chat_id: 42, text: a_string_including("kaboom"))
  end

  it "does not raise if the best-effort failure notification itself fails" do
    allow(client).to receive(:get_updates).with(offset: 0).and_return([
      { "update_id" => 1, "message" => { "chat" => { "id" => 42 }, "text" => "boom" } }
    ])
    allow(Telegram::UpdateProcessor).to receive(:call).and_raise(StandardError, "kaboom")
    allow(client).to receive(:send_message).and_raise(StandardError, "telegram is down too")

    expect { described_class.perform_now }.not_to raise_error
    expect(TelegramUpdateCursor.for_bot.last_update_id).to eq(1)
  end
end

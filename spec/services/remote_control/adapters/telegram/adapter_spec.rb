require "rails_helper"

# How Telegram's updates become RemoteControl::Messages. Sending -- HTML
# panes, edits, rich recaps, the command menu -- is exercised over real HTTP
# against a fake Telegram in spec/integration/telegram_remote_control_spec.rb.
RSpec.describe RemoteControl::Adapters::Telegram::Adapter do
  let(:adapter) { described_class.new }

  def update(text = "/panes", from: 42, chat: from, type: "private", is_bot: false, reply_to: nil)
    message = { "chat" => { "id" => chat, "type" => type }, "from" => { "id" => from, "is_bot" => is_bot }, "text" => text }
    message["reply_to_message"] = { "text" => reply_to } if reply_to
    { "update_id" => 1, "message" => message }
  end

  describe "#message_from" do
    it "turns a private message into a RemoteControl::Message" do
      message = adapter.message_from(update(" /pane_33bd ", reply_to: "run 33bd · x"))

      expect(message).to have_attributes(chat_id: 42, user_id: "42", text: "/pane_33bd", reply_to_text: "run 33bd · x")
    end

    it "drops the bot's name from a command picked from the menu" do
      expect(adapter.message_from(update("/screen@my_sandbox_bot 80")).text).to eq("/screen 80")
    end

    it "ignores group chats, bots, and anything that is not a message" do
      expect(adapter.message_from(update(chat: -100, type: "group"))).to be_nil
      expect(adapter.message_from(update(chat: 43))).to be_nil
      expect(adapter.message_from(update(is_bot: true))).to be_nil
      expect(adapter.message_from({ "update_id" => 1, "edited_message" => {} })).to be_nil
    end
  end

  it "makes run commands tappable" do
    expect(adapter.command_link("pane", "33bd")).to eq("/pane_33bd")
  end

  it "identifies its bot by id, never by the secret half of the token", :fake_telegram do
    expect(fake_telegram.token).to eq("123456:fake-token")
    expect(adapter.identity).to eq("telegram:123456")
  end
end

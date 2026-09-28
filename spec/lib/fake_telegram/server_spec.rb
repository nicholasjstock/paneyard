require "rails_helper"

# Pins FakeTelegram::Server to the Bot API behaviour the app depends on, as
# the real client (RemoteControl::Adapters::Telegram::Client) sees it. Extend
# both together when the client learns a new call.
RSpec.describe FakeTelegram::Server, :fake_telegram do
  let(:client) { RemoteControl::Adapters::Telegram::Client.new }

  it "turns away a wrong token" do
    expect { RemoteControl::Adapters::Telegram::Client.new(token: "1:wrong").get_updates(offset: 0) }
      .to raise_error(/getUpdates failed: Unauthorized/)
  end

  it "keeps updates until an offset past them confirms them" do
    fake_telegram.say("one")
    fake_telegram.say("two")

    expect(client.get_updates(offset: 0).map { |update| update.dig("message", "text") }).to eq(%w[one two])
    expect(client.get_updates(offset: 2).map { |update| update.dig("message", "text") }).to eq(%w[two])
    expect(client.get_updates(offset: 3)).to eq([])
  end

  it "keeps a message's plain text after HTML parsing, and caps that at 4096 characters" do
    sent = client.send_message(chat_id: 42, parse_mode: "HTML", text: "title\n<pre>&lt;b&gt; &amp;</pre>")

    expect(sent["text"]).to eq("title\n<b> &")
    expect { client.send_message(chat_id: 42, parse_mode: "HTML", text: "<pre>#{'x' * 4097}</pre>") }
      .to raise_error(/message is too long/)
    expect(client.send_message(chat_id: 42, parse_mode: "HTML", text: "<pre>#{'&amp;' * 4096}</pre>")).to be_present
  end

  it "hands a reply the plain text of the message it replies to" do
    client.send_message(chat_id: 42, parse_mode: "HTML", text: "run 33bd · x\n<pre>pane</pre>")

    fake_telegram.say("go on", reply_to: fake_telegram.messages.last)

    expect(client.get_updates(offset: 0).last.dig("message", "reply_to_message", "text")).to eq("run 33bd · x\npane")
  end

  it "edits only a message it sent" do
    sent = client.send_message(chat_id: 42, text: "first")

    client.edit_message_text(chat_id: 42, message_id: sent["message_id"], text: "second")

    expect(fake_telegram.messages.last).to have_attributes(text: "second", edits: 1)
    expect { client.edit_message_text(chat_id: 42, message_id: 999, text: "x") }.to raise_error(/message to edit not found/)
  end
end

require "rails_helper"

RSpec.describe DeliverTelegramAdminChatResponseJob do
  let(:client) { instance_double(Telegram::Client, send_message: true, edit_message_text: true) }

  before { allow(Telegram::Client).to receive(:new).and_return(client) }

  it "delivers a completed admin response once to its originating Telegram conversation" do
    workspace = Workspace.create!(name: "Telegram delivery #{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    chat = workspace.create_workspace_admin_chat!
    conversation = TelegramConversation.create!(telegram_chat_id: "123", telegram_user_id: "42", workspace:)
    message = chat.messages.create!(role: "assistant", provider: "codex", turn_id: SecureRandom.uuid, status: "completed", content: "All done.", telegram_conversation: conversation)

    described_class.perform_now(message.id)
    described_class.perform_now(message.id)

    expect(client).to have_received(:send_message).once.with(chat_id: "123", text: "All done.")
    expect(message.reload.telegram_delivered_at).to be_present
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && Dir.exist?(workspace.root_path)
  end

  it "edits the originating working message when one was recorded" do
    workspace = Workspace.create!(name: "Telegram edit #{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    chat = workspace.create_workspace_admin_chat!
    conversation = TelegramConversation.create!(telegram_chat_id: "123", telegram_user_id: "42", workspace:)
    message = chat.messages.create!(role: "assistant", provider: "codex", turn_id: SecureRandom.uuid, status: "completed", content: "All done.", telegram_conversation: conversation, telegram_message_id: 456)

    described_class.perform_now(message.id)

    expect(client).to have_received(:edit_message_text).with(chat_id: "123", message_id: 456, text: "All done.")
    expect(client).not_to have_received(:send_message)
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && Dir.exist?(workspace.root_path)
  end
end

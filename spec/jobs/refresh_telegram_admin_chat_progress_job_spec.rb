require "rails_helper"

RSpec.describe RefreshTelegramAdminChatProgressJob do
  let(:client) { instance_double(Telegram::Client, send_chat_action: true, edit_message_text: true) }

  before { allow(Telegram::Client).to receive(:new).and_return(client) }

  it "keeps Telegram typing and edits the working message with streamed content" do
    workspace = Workspace.create!(name: "Telegram progress #{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    chat = workspace.create_workspace_admin_chat!
    conversation = TelegramConversation.create!(telegram_chat_id: "123", telegram_user_id: "42", workspace:)
    message = chat.messages.create!(role: "assistant", provider: "codex", turn_id: SecureRandom.uuid, status: "running", content: "Streaming answer", telegram_conversation: conversation, telegram_message_id: 456, telegram_synced_content: "Working…")

    described_class.perform_now

    expect(client).to have_received(:send_chat_action).with(chat_id: "123", action: "typing")
    expect(client).to have_received(:edit_message_text).with(chat_id: "123", message_id: 456, text: "Streaming answer")
    expect(message.reload.telegram_synced_content).to eq("Streaming answer")
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && Dir.exist?(workspace.root_path)
  end
end

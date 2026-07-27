require "rails_helper"

RSpec.describe RefreshTelegramAdminChatProgressJob do
  let(:client) { instance_double(Telegram::Client, send_rich_message: true, send_rich_message_draft: true) }

  before { allow(Telegram::Client).to receive(:new).and_return(client) }

  it "uses Telegram's native AI draft stream when the message has a draft id" do
    workspace = Workspace.create!(name: "Telegram native draft #{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    chat = workspace.create_workspace_admin_chat!
    conversation = TelegramConversation.create!(telegram_chat_id: "123", telegram_user_id: "42", workspace:)
    chat.messages.create!(role: "assistant", provider: "codex", turn_id: SecureRandom.uuid, status: "running", content: "Streaming answer", telegram_conversation: conversation, telegram_draft_id: 456)

    described_class.perform_now

    expect(client).to have_received(:send_rich_message_draft).with(chat_id: "123", draft_id: 456, html: "Streaming answer")
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && Dir.exist?(workspace.root_path)
  end

  it "persists a full draft chunk and starts a fresh draft for the remainder" do
    workspace = Workspace.create!(name: "Telegram chunked draft #{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    chat = workspace.create_workspace_admin_chat!
    conversation = TelegramConversation.create!(telegram_chat_id: "123", telegram_user_id: "42", workspace:)
    content = ("a" * 4096) + "b"
    message = chat.messages.create!(role: "assistant", provider: "codex", turn_id: SecureRandom.uuid, status: "running", content:, telegram_conversation: conversation, telegram_draft_id: 456)

    described_class.perform_now

    expect(client).to have_received(:send_rich_message).with(chat_id: "123", markdown: "a" * 4096)
    expect(client).to have_received(:send_rich_message_draft).with(chat_id: "123", draft_id: kind_of(Integer), html: "b")
    expect(message.reload.telegram_persisted_characters).to eq(4096)
    expect(message.telegram_draft_id).not_to eq(456)
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && Dir.exist?(workspace.root_path)
  end
end

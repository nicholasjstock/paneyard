require "rails_helper"

RSpec.describe DeliverTelegramAdminChatResponseJob do
  let(:client) { instance_double(Telegram::Client, send_rich_message: true) }

  before { allow(Telegram::Client).to receive(:new).and_return(client) }

  it "delivers a completed admin response once to its originating Telegram conversation" do
    workspace = Workspace.create!(name: "Telegram delivery #{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    chat = workspace.create_workspace_admin_chat!
    conversation = TelegramConversation.create!(telegram_chat_id: "123", telegram_user_id: "42", workspace:)
    message = chat.messages.create!(role: "assistant", provider: "codex", turn_id: SecureRandom.uuid, status: "completed", content: "All done.", telegram_conversation: conversation)

    described_class.perform_now(message.id)
    described_class.perform_now(message.id)

    expect(client).to have_received(:send_rich_message).once.with(chat_id: "123", markdown: "All done.")
    expect(message.reload.telegram_delivered_at).to be_present
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && Dir.exist?(workspace.root_path)
  end

  it "persists a native Telegram draft as a rich message" do
    workspace = Workspace.create!(name: "Telegram draft #{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    chat = workspace.create_workspace_admin_chat!
    conversation = TelegramConversation.create!(telegram_chat_id: "123", telegram_user_id: "42", workspace:)
    message = chat.messages.create!(role: "assistant", provider: "codex", turn_id: SecureRandom.uuid, status: "completed", content: "All done.", telegram_conversation: conversation, telegram_draft_id: 456)

    described_class.perform_now(message.id)

    expect(client).to have_received(:send_rich_message).with(chat_id: "123", markdown: "All done.")
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && Dir.exist?(workspace.root_path)
  end

  it "only persists the final chunk when earlier chunks were already streamed" do
    workspace = Workspace.create!(name: "Telegram chunks #{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    chat = workspace.create_workspace_admin_chat!
    conversation = TelegramConversation.create!(telegram_chat_id: "123", telegram_user_id: "42", workspace:)
    content = ("a" * 4096) + "b"
    message = chat.messages.create!(role: "assistant", provider: "codex", turn_id: SecureRandom.uuid, status: "completed", content:, telegram_conversation: conversation, telegram_draft_id: 456, telegram_persisted_characters: 4096)

    described_class.perform_now(message.id)

    expect(client).to have_received(:send_rich_message).once.with(chat_id: "123", markdown: "b")
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && Dir.exist?(workspace.root_path)
  end
end

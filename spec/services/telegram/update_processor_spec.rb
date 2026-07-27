require "rails_helper"

RSpec.describe Telegram::UpdateProcessor do
  let(:client) { instance_double(Telegram::Client, send_message: { "message_id" => 456 }, send_chat_action: true, send_rich_message_draft: true, answer_callback_query: true) }
  let!(:workspace) { Workspace.create!(name: "Telegram workspace #{SecureRandom.hex(4)}", root_path: Dir.mktmpdir) }

  before do
    allow(Telegram::Client).to receive(:new).and_return(client)
    allow(Telegram::Configuration).to receive(:authorized_user?).with("42").and_return(true)
  end

  after do
    FileUtils.remove_entry(workspace.root_path) if Dir.exist?(workspace.root_path)
  end

  def message(text)
    { "message" => { "chat" => { "id" => 123 }, "from" => { "id" => 42 }, "text" => text } }
  end

  it "shows workspace-selection buttons for /workspaces" do
    described_class.call(message("/workspaces"))

    expect(client).to have_received(:send_message).with(
      chat_id: "123", text: "Choose a workspace:",
      reply_markup: { inline_keyboard: [ [ { text: workspace.name, callback_data: "workspace:#{workspace.id}" } ] ] }
    )
  end

  it "selects a workspace from its callback button" do
    described_class.call(
      "callback_query" => {
        "id" => "callback-1", "from" => { "id" => 42 }, "data" => "workspace:#{workspace.id}",
        "message" => { "chat" => { "id" => 123 } }
      }
    )

    conversation = TelegramConversation.find_by!(telegram_chat_id: "123")
    expect(conversation.workspace).to eq(workspace)
    expect(client).to have_received(:answer_callback_query).with(callback_query_id: "callback-1")
    expect(client).to have_received(:send_message).with(chat_id: "123", text: "Selected #{workspace.name}. Send a message to its admin chat.")
  end

  it "starts the selected workspace's admin chat and records the originating conversation" do
    conversation = TelegramConversation.create!(telegram_chat_id: "123", telegram_user_id: "42", workspace:)
    assistant_message = instance_double(WorkspaceAdminChatMessage, update!: true)

    expect(Orchestrator::WorkspaceAdminChatDriver::Runner).to receive(:start_turn!) do |chat:, content:, telegram_conversation:|
      expect(chat.workspace).to eq(workspace)
      expect(content).to eq("check the run")
      expect(telegram_conversation).to eq(conversation)
      assistant_message
    end

    described_class.call(message("check the run"))

    expect(client).to have_received(:send_rich_message_draft).with(
      chat_id: "123", draft_id: kind_of(Integer), html: "<tg-thinking>Working in #{workspace.name}…</tg-thinking>"
    )
    expect(client).to have_received(:send_chat_action).with(chat_id: "123", action: "typing")
    expect(assistant_message).to have_received(:update!).with(telegram_draft_id: kind_of(Integer))
  end

  it "reports the selected workspace's active provider, model, and status" do
    conversation = TelegramConversation.create!(telegram_chat_id: "123", telegram_user_id: "42", workspace:)
    chat = workspace.create_workspace_admin_chat!(active_provider: "codex", codex_model: Orchestrator::WorkerSpawner::CODEX_PROMOTED_MODEL)

    described_class.call(message("/status"))

    expect(client).to have_received(:send_message).with(
      chat_id: "123", text: "#{workspace.name}\nProvider: codex\nModel: #{chat.codex_model}\nStatus: idle"
    )
  end

  it "switches provider, changes its model, and resets that provider's session" do
    TelegramConversation.create!(telegram_chat_id: "123", telegram_user_id: "42", workspace:)
    chat = workspace.create_workspace_admin_chat!(active_provider: "claude", claude_session_id: "old-session")

    described_class.call(message("/provider codex"))
    described_class.call(message("/model #{Orchestrator::WorkerSpawner::CODEX_PROMOTED_MODEL}"))
    described_class.call(message("/reset"))

    chat.reload
    expect(chat.active_provider).to eq("codex")
    expect(chat.codex_model).to eq(Orchestrator::WorkerSpawner::CODEX_PROMOTED_MODEL)
    expect(chat.codex_session_id).to be_nil
    expect(client).to have_received(:send_message).with(chat_id: "123", text: "Reset the codex session. Message history is retained.")
  end

  it "does not process a message from an unauthorized user" do
    allow(Telegram::Configuration).to receive(:authorized_user?).with("99").and_return(false)

    described_class.call("message" => { "chat" => { "id" => 999 }, "from" => { "id" => 99 }, "text" => "/workspaces" })

    expect(TelegramConversation.find_by(telegram_chat_id: "999")).to be_nil
    expect(client).not_to have_received(:send_message)
  end
end

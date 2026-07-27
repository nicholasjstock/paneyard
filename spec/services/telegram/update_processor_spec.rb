require "rails_helper"

RSpec.describe Telegram::UpdateProcessor do
  let(:client) { instance_double(Telegram::Client, send_message: true, answer_callback_query: true) }
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
    assistant_message = instance_double(WorkspaceAdminChatMessage)

    expect(Orchestrator::WorkspaceAdminChatDriver::Runner).to receive(:start_turn!) do |chat:, content:, telegram_conversation:|
      expect(chat.workspace).to eq(workspace)
      expect(content).to eq("check the run")
      expect(telegram_conversation).to eq(conversation)
      assistant_message
    end

    described_class.call(message("check the run"))

    expect(client).to have_received(:send_message).with(chat_id: "123", text: "Working in #{workspace.name}…")
  end

  it "does not process a message from an unauthorized user" do
    allow(Telegram::Configuration).to receive(:authorized_user?).with("99").and_return(false)

    described_class.call("message" => { "chat" => { "id" => 999 }, "from" => { "id" => 99 }, "text" => "/workspaces" })

    expect(TelegramConversation.find_by(telegram_chat_id: "999")).to be_nil
    expect(client).not_to have_received(:send_message)
  end
end

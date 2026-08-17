require "rails_helper"

RSpec.describe "workspace admin chat messages", type: :request do
  def create_workspace
    Workspace.create!(name: "admin-chat-req-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir("admin-chat-req"))
  end

  it "enqueues a turn job for a new message and redirects back" do
    workspace = create_workspace

    expect {
      post workspace_workspace_admin_chat_messages_path(workspace), params: { workspace_admin_chat_message: { content: "hello" } }
    }.to have_enqueued_job(WorkspaceAdminChatTurnJob)

    expect(response).to redirect_to(workspace_runs_path(workspace))
    chat = workspace.reload.workspace_admin_chat
    expect(chat.active?).to be(true)
    expect(chat.messages.find_by(role: "user").content).to eq("hello")
  end

  it "rejects a blank message without starting a turn" do
    workspace = create_workspace

    expect {
      post workspace_workspace_admin_chat_messages_path(workspace), params: { workspace_admin_chat_message: { content: "   " } }
    }.not_to have_enqueued_job(WorkspaceAdminChatTurnJob)

    expect(response).to redirect_to(workspace_runs_path(workspace))
    expect(flash[:alert]).to be_present
  end

  it "prevents a second concurrent turn for the same workspace" do
    workspace = create_workspace
    post workspace_workspace_admin_chat_messages_path(workspace), params: { workspace_admin_chat_message: { content: "first" } }

    expect {
      post workspace_workspace_admin_chat_messages_path(workspace), params: { workspace_admin_chat_message: { content: "second" } }
    }.not_to have_enqueued_job(WorkspaceAdminChatTurnJob)

    expect(flash[:alert]).to match(/wait/i)
    expect(workspace.reload.workspace_admin_chat.messages.count).to eq(2)
  end
end

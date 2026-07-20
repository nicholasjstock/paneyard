require "rails_helper"

RSpec.describe "workspace chat messages", type: :request do
  it "switches the chat's driver when launcher_variant is posted alongside a message" do
    workspace, chat = create_workspace_with_chat

    post workspace_chat_messages_path(workspace, chat),
      params: { launcher_variant: "codex", workspace_chat_message: { content: "Switch to codex" } }

    assert_equal "codex", chat.reload.launcher_variant
  end

  it "leaves the driver unchanged when launcher_variant is omitted" do
    workspace, chat = create_workspace_with_chat
    chat.update!(launcher_variant: "codex")

    post workspace_chat_messages_path(workspace, chat), params: { workspace_chat_message: { content: "Keep going" } }

    assert_equal "codex", chat.reload.launcher_variant
  end

  it "ignores an unsupported launcher_variant instead of raising" do
    workspace, chat = create_workspace_with_chat

    expect {
      post workspace_chat_messages_path(workspace, chat),
        params: { launcher_variant: "gpt4", workspace_chat_message: { content: "Try something else" } }
    }.not_to raise_error

    assert_equal "claude", chat.reload.launcher_variant
  end

  def create_workspace_with_chat
    workspace = Workspace.create!(name: "chat-messages-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    [ workspace, workspace.workspace_chats.create! ]
  end
end

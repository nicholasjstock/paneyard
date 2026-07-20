require "rails_helper"

RSpec.describe WorkspaceChat, type: :model do
  it "defaults to claude and accepts either supported launcher variant" do
    workspace = Workspace.create!(name: "workspace-chat-model-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)

    chat = workspace.workspace_chats.create!

    assert_equal "claude", chat.launcher_variant
    assert chat.update(launcher_variant: "codex")
  end

  it "rejects an unsupported launcher variant" do
    workspace = Workspace.create!(name: "workspace-chat-model-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    chat = workspace.workspace_chats.create!

    refute chat.update(launcher_variant: "gpt4")
  end
end

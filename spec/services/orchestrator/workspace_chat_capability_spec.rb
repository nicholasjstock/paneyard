require "rails_helper"

RSpec.describe Orchestrator::WorkspaceChatCapability do
  it "authenticates only the chat named by the signed capability" do
    workspace = Workspace.create!(name: "capability-#{SecureRandom.hex(4)}", root_path: "/tmp/#{SecureRandom.hex(8)}")
    chat = workspace.workspace_chats.create!

    token = Orchestrator::WorkspaceChatCapability.issue(chat)

    assert_equal chat, Orchestrator::WorkspaceChatCapability.authenticate(token)
    assert_nil Orchestrator::WorkspaceChatCapability.authenticate("not-a-token")
  end
end

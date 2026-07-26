require "rails_helper"

RSpec.describe WorkspaceAdminChatTurnJob do
  def create_chat
    workspace = Workspace.create!(name: "admin-chat-job-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir("admin-chat-job"))
    workspace.create_workspace_admin_chat!
  end

  it "delegates to Runner.perform_turn for a running assistant message" do
    chat = create_chat
    message = chat.messages.create!(role: "assistant", provider: "claude", status: "running", turn_id: SecureRandom.uuid)

    expect(Orchestrator::WorkspaceAdminChatDriver::Runner).to receive(:perform_turn).with(message)

    described_class.perform_now(message.id)
  end

  it "does nothing for a message that is no longer running (already cancelled/completed elsewhere)" do
    chat = create_chat
    message = chat.messages.create!(role: "assistant", provider: "claude", status: "cancelled", turn_id: SecureRandom.uuid)

    expect(Orchestrator::WorkspaceAdminChatDriver::Runner).not_to receive(:perform_turn)

    described_class.perform_now(message.id)
  end
end

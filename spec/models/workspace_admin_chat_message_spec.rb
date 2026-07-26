require "rails_helper"

RSpec.describe WorkspaceAdminChatMessage do
  def create_message
    workspace = Workspace.create!(name: "admin-chat-msg-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir("admin-chat-msg"))
    chat = workspace.create_workspace_admin_chat!
    chat.messages.create!(role: "assistant", provider: "claude", status: "running", turn_id: SecureRandom.uuid)
  end

  it "accumulates assistant_delta text onto content" do
    message = create_message

    message.apply_event!(type: "assistant_delta", text: "Hel")
    message.apply_event!(type: "assistant_delta", text: "lo")

    expect(message.reload.content).to eq("Hello")
    expect(message.events.map { |e| e["type"] }).to eq(%w[assistant_delta assistant_delta])
  end

  it "replaces content outright on assistant_completed" do
    message = create_message

    message.apply_event!(type: "assistant_delta", text: "partial")
    message.apply_event!(type: "assistant_completed", text: "final answer")

    expect(message.reload.content).to eq("final answer")
  end

  it "records usage from turn_completed and the error message from an error event" do
    message = create_message

    message.apply_event!(type: "turn_completed", usage: { "input_tokens" => 5 })
    message.apply_event!(type: "error", message: "boom")

    message.reload
    expect(message.usage).to eq({ "input_tokens" => 5 })
    expect(message.error_message).to eq("boom")
  end

  it "appends every event to the events log even when it doesn't affect content" do
    message = create_message

    message.apply_event!(type: "tool_started", id: "t1", name: "Bash")
    message.apply_event!(type: "tool_completed", id: "t1", result: "ok")
    message.apply_event!(type: "file_changed", path: "/tmp/a.rb")

    expect(message.reload.events.map { |e| e["type"] }).to eq(%w[tool_started tool_completed file_changed])
  end
end

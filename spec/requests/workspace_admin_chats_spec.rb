require "rails_helper"

RSpec.describe "workspace admin chats", type: :request do
  def create_workspace
    Workspace.create!(name: "admin-chat-ctrl-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir("admin-chat-ctrl"))
  end

  it "lazily creates the chat on first settings update" do
    workspace = create_workspace

    patch workspace_workspace_admin_chat_path(workspace), params: { active_provider: "claude" }

    expect(response).to redirect_to(workspace_runs_path(workspace))
    expect(workspace.reload.workspace_admin_chat).to be_present
  end

  it "switches the active provider and lets each provider keep its own hardcoded model override" do
    workspace = create_workspace

    patch workspace_workspace_admin_chat_path(workspace), params: { active_provider: "codex", codex_model: WorkspaceAdminChat::CODEX_MODELS.last }

    chat = workspace.reload.workspace_admin_chat
    expect(chat.active_provider).to eq("codex")
    expect(chat.codex_model).to eq(WorkspaceAdminChat::CODEX_MODELS.last)
  end

  it "ignores an invalid provider value instead of raising" do
    workspace = create_workspace

    patch workspace_workspace_admin_chat_path(workspace), params: { active_provider: "not-a-real-provider" }

    expect(response).to redirect_to(workspace_runs_path(workspace))
    expect(workspace.reload.workspace_admin_chat.active_provider).to eq("claude")
  end

  it "ignores a model value outside the hardcoded list for the given provider" do
    workspace = create_workspace

    patch workspace_workspace_admin_chat_path(workspace), params: { claude_model: "not-a-real-model" }

    expect(workspace.reload.workspace_admin_chat.claude_model).to be_nil
  end

  it "resets a provider's session id without touching the other provider or message history" do
    workspace = create_workspace
    chat = workspace.create_workspace_admin_chat!
    chat.set_session_id!("claude", "claude-sess")
    chat.set_session_id!("codex", "codex-sess")
    chat.messages.create!(role: "user", provider: "claude", status: "completed", content: "hi")

    post reset_workspace_workspace_admin_chat_path(workspace), params: { provider: "claude" }

    chat.reload
    expect(chat.claude_session_id).to be_nil
    expect(chat.codex_session_id).to eq("codex-sess")
    expect(chat.messages.count).to eq(1)
  end

  it "refuses to reset the active provider's conversation while its turn is running" do
    workspace = create_workspace
    chat = workspace.create_workspace_admin_chat!
    chat.update!(active_turn_id: SecureRandom.uuid, status: "running")
    chat.set_session_id!("claude", "claude-sess")

    post reset_workspace_workspace_admin_chat_path(workspace), params: { provider: "claude" }

    expect(flash[:alert]).to be_present
    expect(chat.reload.claude_session_id).to eq("claude-sess")
  end

  it "delivers a cancel request for an active turn" do
    workspace = create_workspace
    chat = workspace.create_workspace_admin_chat!
    chat.update!(active_turn_id: SecureRandom.uuid, status: "running")

    post cancel_workspace_workspace_admin_chat_path(workspace)

    expect(response).to redirect_to(workspace_runs_path(workspace))
    # No pid was ever recorded for this turn (it wasn't actually started by
    # a job here) -- cancel_turn! falls back to clearing the stuck slot
    # directly, same as a crashed-job recovery.
    expect(chat.reload.active_turn_id).to be_nil
  end
end

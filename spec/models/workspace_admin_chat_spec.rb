require "rails_helper"

RSpec.describe WorkspaceAdminChat do
  def create_chat
    workspace = Workspace.create!(name: "admin-chat-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir("admin-chat"))
    workspace.create_workspace_admin_chat!
  end

  it "defaults to the claude provider and idle status" do
    chat = create_chat

    expect(chat.active_provider).to eq("claude")
    expect(chat.status).to eq("idle")
    expect(chat.active?).to be(false)
  end

  it "keeps independent claude/codex session ids so switching providers preserves both" do
    chat = create_chat

    chat.set_session_id!("claude", "claude-sess-1")
    chat.set_session_id!("codex", "codex-sess-1")

    expect(chat.session_id_for("claude")).to eq("claude-sess-1")
    expect(chat.session_id_for("codex")).to eq("codex-sess-1")

    chat.update!(active_provider: "codex")
    expect(chat.session_id_for("claude")).to eq("claude-sess-1")
  end

  it "never overwrites a session id with a blank value" do
    chat = create_chat
    chat.set_session_id!("claude", "claude-sess-1")

    chat.set_session_id!("claude", nil)
    chat.set_session_id!("claude", "")

    expect(chat.session_id_for("claude")).to eq("claude-sess-1")
  end

  it "resets only the requested provider's session id" do
    chat = create_chat
    chat.set_session_id!("claude", "claude-sess-1")
    chat.set_session_id!("codex", "codex-sess-1")

    chat.reset_session!("claude")

    expect(chat.session_id_for("claude")).to be_nil
    expect(chat.session_id_for("codex")).to eq("codex-sess-1")
  end

  it "is active only while a turn id is set" do
    chat = create_chat
    expect(chat.active?).to be(false)

    chat.update!(active_turn_id: SecureRandom.uuid)
    expect(chat.active?).to be(true)
  end

  it "enforces one admin chat per workspace" do
    chat = create_chat

    expect { chat.workspace.create_workspace_admin_chat! }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "falls back to the first hardcoded model for a provider until one is explicitly set" do
    chat = create_chat

    expect(chat.model_for("claude")).to eq(WorkspaceAdminChat::CLAUDE_MODELS.first)
    expect(chat.model_for("codex")).to eq(WorkspaceAdminChat::CODEX_MODELS.first)

    chat.update!(claude_model: WorkspaceAdminChat::CLAUDE_MODELS.last)
    expect(chat.model_for("claude")).to eq(WorkspaceAdminChat::CLAUDE_MODELS.last)
  end

  it "scopes the hardcoded model list to the given provider" do
    expect(described_class.models_for("claude")).to eq(WorkspaceAdminChat::CLAUDE_MODELS)
    expect(described_class.models_for("codex")).to eq(WorkspaceAdminChat::CODEX_MODELS)
  end

  it "shows only the currently active provider's own messages -- each provider's context is a separate CLI session" do
    chat = create_chat
    claude_message = chat.messages.create!(role: "user", provider: "claude", status: "completed", content: "claude turn")
    codex_message = chat.messages.create!(role: "user", provider: "codex", status: "completed", content: "codex turn")

    expect(chat.visible_messages).to contain_exactly(claude_message)

    chat.update!(active_provider: "codex")
    expect(chat.visible_messages).to contain_exactly(codex_message)
  end
end

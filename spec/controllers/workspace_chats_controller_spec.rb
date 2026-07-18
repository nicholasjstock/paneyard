require "rails_helper"

RSpec.describe WorkspaceChatsController, type: :request do
  it "each workspace opens and retains its own single chat history" do
    first = create_workspace("first")
    second = create_workspace("second")
    first_chat = first.workspace_chats.create!
    first_chat.messages.create!(role: "user", content: "Remember the first project", status: "completed")
    second_chat = second.workspace_chats.create!
    second_chat.messages.create!(role: "user", content: "Remember the second project", status: "completed")

    get workspace_chats_path(first)
    expect(response).to redirect_to(workspace_chat_path(first, first_chat))
    follow_redirect!
    expect(response).to have_http_status(:success)
    expect(response.body).to include("Remember the first project")
    expect(response.body).not_to include("Remember the second project")

    get workspace_chats_path(second)
    expect(response).to redirect_to(workspace_chat_path(second, second_chat))
    expect(first.workspace_chats.count).to eq(1)
    expect(second.workspace_chats.count).to eq(1)
  end

  it "run view embeds the workspace history in an operator drawer" do
    workspace = create_workspace("drawer")
    chat = workspace.workspace_chats.create!
    chat.messages.create!(role: "assistant", content: "This project's retained answer", status: "completed")
    run = workspace.runs.create!(
      run_id: "drawer-#{SecureRandom.hex(4)}", task: "Render the drawer", target_root: workspace.root_path,
      launcher_variant: "codex", status: "stopped"
    )

    get workspace_run_path(workspace, run)

    expect(response).to have_http_status(:success)
    expect(response.body).to include("Open project chat")
    expect(response.body).to include("This project's retained answer")
    expect(response.body).to include("chat-drawer")
  end

  private

  def create_workspace(label)
    Workspace.create!(name: "#{label}-#{SecureRandom.hex(4)}", root_path: "/tmp/#{SecureRandom.hex(8)}")
  end
end

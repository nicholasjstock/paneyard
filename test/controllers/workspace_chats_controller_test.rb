require "test_helper"

class WorkspaceChatsControllerTest < ActionDispatch::IntegrationTest
  test "each workspace opens and retains its own single chat history" do
    first = create_workspace("first")
    second = create_workspace("second")
    first_chat = first.workspace_chats.create!
    first_chat.messages.create!(role: "user", content: "Remember the first project", status: "completed")
    second_chat = second.workspace_chats.create!
    second_chat.messages.create!(role: "user", content: "Remember the second project", status: "completed")

    get workspace_chats_path(first)
    assert_redirected_to workspace_chat_path(first, first_chat)
    follow_redirect!
    assert_response :success
    assert_includes response.body, "Remember the first project"
    refute_includes response.body, "Remember the second project"

    get workspace_chats_path(second)
    assert_redirected_to workspace_chat_path(second, second_chat)
    assert_equal 1, first.workspace_chats.count
    assert_equal 1, second.workspace_chats.count
  end

  test "run view embeds the workspace history in an operator drawer" do
    workspace = create_workspace("drawer")
    chat = workspace.workspace_chats.create!
    chat.messages.create!(role: "assistant", content: "This project's retained answer", status: "completed")
    run = workspace.runs.create!(
      run_id: "drawer-#{SecureRandom.hex(4)}", task: "Render the drawer", target_root: workspace.root_path,
      launcher_variant: "codex", status: "stopped"
    )

    get workspace_run_path(workspace, run)

    assert_response :success
    assert_includes response.body, "Open project chat"
    assert_includes response.body, "This project's retained answer"
    assert_includes response.body, "chat-drawer"
  end

  private

  def create_workspace(label)
    Workspace.create!(name: "#{label}-#{SecureRandom.hex(4)}", root_path: "/tmp/#{SecureRandom.hex(8)}")
  end
end

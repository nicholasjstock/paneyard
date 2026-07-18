require "test_helper"

class WorkspaceChatRunControlToolTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  teardown { WorkspaceChatContext.reset }

  test "resumes a run and queues orchestration only inside the chat workspace" do
    own_workspace, chat = create_workspace_with_chat("own")
    other_workspace, = create_workspace_with_chat("other")
    run = create_run(own_workspace, "own-run")
    other_run = create_run(other_workspace, "other-run")
    WorkspaceChatContext.chat = chat

    assert_enqueued_with(job: TickRunJob) do
      McpTools::WorkspaceChatRunControlTool.call(runId: run.run_id, action: "resume", server_context: nil)
    end

    assert_equal "running", run.reload.status
    assert_equal "planning", run.phase
    assert_raises(ActiveRecord::RecordNotFound) do
      McpTools::WorkspaceChatRunControlTool.call(runId: other_run.run_id, action: "resume", server_context: nil)
    end
  end

  private

  def create_workspace_with_chat(label)
    workspace = Workspace.create!(name: "#{label}-#{SecureRandom.hex(4)}", root_path: "/tmp/#{SecureRandom.hex(8)}")
    [ workspace, workspace.workspace_chats.create! ]
  end

  def create_run(workspace, run_id)
    workspace.runs.create!(
      run_id: "#{run_id}-#{SecureRandom.hex(4)}", task: "Test run", target_root: workspace.root_path,
      launcher_variant: "codex", status: "stopped"
    )
  end
end

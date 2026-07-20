require "rails_helper"

RSpec.describe McpTools::WorkspaceChatRunControlTool do
  include ActiveJob::TestHelper

  it "resumes a run and queues orchestration only inside the chat workspace" do
    own_workspace, chat = create_workspace_with_chat("own")
    other_workspace, = create_workspace_with_chat("other")
    run = create_run(own_workspace, "own-run")
    other_run = create_run(other_workspace, "other-run")

    assert_enqueued_with(job: TickRunJob) do
      McpTools::WorkspaceChatRunControlTool.call(runId: run.run_id, action: "resume", server_context: { chat_id: chat.id })
    end

    assert_equal "running", run.reload.status
    assert_equal "planning", run.phase
    assert_raises(ActiveRecord::RecordNotFound) do
      McpTools::WorkspaceChatRunControlTool.call(runId: other_run.run_id, action: "resume", server_context: { chat_id: chat.id })
    end
  end

  it "resumes a completed tick and requests recovery work instead of completing again" do
    workspace, chat = create_workspace_with_chat("completed")
    run = create_run(workspace, "completed-run")
    run.update!(status: "completed", stopped_at: Time.current)
    Orchestrator::TickState.write(
      run_id: run.run_id, phase: "completed", tick_count: 4,
      last_plan_summary: "Verification ended blocked.", pending_spawn_keys: [], following_steps: []
    )

    perform_enqueued_jobs do
      described_class.call(runId: run.run_id, action: "resume", server_context: { chat_id: chat.id })
    end

    expect(run.reload.status).to eq("running")
    expect(run.stopped_at).to be_nil
    expect(Orchestrator::TickState.latest(run.run_id)[:phase]).to eq("planning")
    expect(run.spawn_requests.open_only.find_by(requested_role: "planner")).to be_present
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

require "rails_helper"

RSpec.describe "turn routing" do
  it "promotes a queued step after DONE without requesting another planner" do
    run = build_run
    previous_state = Orchestrator::TickState.write(
      run_id: run.run_id, phase: "waiting_on_workers", tick_count: 1,
      last_plan_summary: "Implement then verify.", pending_spawn_keys: [],
      following_steps: [ {
        owner: "worker", artifact: "verify.md", success_check: "Confirm behavior.",
        mode: "verification", write_scope: "artifact_only", allowed_paths: [], evidence_refs: []
      } ]
    )

    result = Orchestrator::Turn.run_worker_turn(
      run_id: run.run_id, role: "worker", nickname: "worker-1", scope: "fix.md",
      result: "[DONE] Fix verified locally.", previous_state:
    )

    assert result[:promoted_preplanned_step]
    assert_nil result[:planner_request]
    assert_equal "verify.md", run.spawn_requests.open_only.find_by!(requested_role: "worker").scope
    assert_empty result.dig(:next_state, :following_steps)
  end

  private

  def build_run
    workspace = Workspace.create!(name: "turn-routing-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s)
    workspace.runs.create!(
      run_id: "turn-routing-#{SecureRandom.hex(4)}", task: "Complete the workflow",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
  end
end

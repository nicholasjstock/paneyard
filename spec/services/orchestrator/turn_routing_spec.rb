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

  it "records which acceptance criterion a Rails-auto-promoted followingSteps item addresses" do
    run = build_run
    criterion = run.acceptance_criteria.create!(key: "demo-verified", content: "Demo behavior verified", status: "pending")
    previous_state = Orchestrator::TickState.write(
      run_id: run.run_id, phase: "waiting_on_workers", tick_count: 1,
      last_plan_summary: "Implement then verify.", pending_spawn_keys: [],
      following_steps: [ {
        owner: "worker", artifact: "verify.md", success_check: "Confirm behavior.",
        mode: "verification", write_scope: "artifact_only", allowed_paths: [], evidence_refs: [],
        addresses_criteria: [ "demo-verified" ]
      } ]
    )

    Orchestrator::Turn.run_worker_turn(
      run_id: run.run_id, role: "worker", nickname: "worker-1", scope: "fix.md",
      result: "[DONE] Fix verified locally.", previous_state:
    )

    step = AcceptanceCriterionStep.find_by!(acceptance_criterion: criterion)
    assert_equal "verify.md", step.lineage_key
    assert_equal "in_progress", criterion.reload.status
  end

  it "keeps later verifier siblings pending while the active branch is unresolved" do
    run = build_run
    run.acceptance_criteria.create!(key: "baseline", content: "Baseline is measured", status: "in_progress")
    run.acceptance_criteria.create!(key: "bottlenecks", content: "Bottlenecks are measured", status: "pending")
    run.update!(active_branch_key: "baseline")
    previous_state = Orchestrator::TickState.write(
      run_id: run.run_id, phase: "waiting_on_workers", tick_count: 1,
      last_plan_summary: "Verify baseline, then bottlenecks.", pending_spawn_keys: [],
      following_steps: [ {
        owner: "worker", artifact: "verify-bottlenecks.md", success_check: "Confirm bottlenecks.",
        mode: "verification", write_scope: "artifact_only", allowed_paths: [], evidence_refs: [],
        addresses_criteria: [ "bottlenecks" ]
      } ]
    )

    result = Orchestrator::Turn.run_worker_turn(
      run_id: run.run_id, role: "verifier", nickname: "verifier", scope: "verify-baseline.md",
      result: "[DONE] Baseline evidence was rejected; more measurement is required.", previous_state:
    )

    refute result[:promoted_preplanned_step]
    assert_equal "workflow-plan.md", SpawnRequest.open_only.find_by!(requested_role: "planner").scope
    refute SpawnRequest.exists?(run_id: run.run_id, scope: "verify-bottlenecks.md")
    assert_equal [ "verify-bottlenecks.md" ], result.dig(:next_state, :following_steps).map { |step| step[:artifact] }
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

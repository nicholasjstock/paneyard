require "rails_helper"

RSpec.describe Orchestrator::Turn do
  it "planner completion stays blocked when an operator answer is open" do
    workspace = Workspace.create!(name: "turn-test-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s)
    run = Run.create!(
      workspace: workspace,
      run_id: "turn-test-#{SecureRandom.hex(4)}",
      task: "Test blocked planner completion",
      target_root: Rails.root.to_s,
      launcher_variant: "codex",
      status: "running"
    )
    UserQuestion.create!(
      run_id: run.run_id,
      asked_by: "planner",
      scope: "recording.md",
      text: "Choose how to continue.",
      priority: "blocking",
      status: "open"
    )

    result = Orchestrator::Turn.run_planner_turn(
      run_id: run.run_id,
      summary: "Waiting for the operator.",
      next_step: nil,
      following_steps: [],
      previous_state: Orchestrator::TickState.default_state(run.run_id)
    )

    assert_equal "awaiting_user_feedback", result.dig(:next_state, :phase)
  end

  it "does not dispatch a new spawn request while an operator answer is open" do
    workspace = Workspace.create!(name: "turn-test-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s)
    run = Run.create!(
      workspace: workspace,
      run_id: "turn-test-#{SecureRandom.hex(4)}",
      task: "Test blocked planner dispatch",
      target_root: Rails.root.to_s,
      launcher_variant: "codex",
      status: "running"
    )
    UserQuestion.create!(
      run_id: run.run_id,
      asked_by: "chaperone",
      scope: "recording.md",
      text: "Choose how to continue.",
      priority: "blocking",
      status: "open"
    )

    result = Orchestrator::Turn.run_planner_turn(
      run_id: run.run_id,
      summary: "Pivoting to a new bounded approach.",
      next_step: {
        owner: "worker", artifact: "baseline.json", success_check: "Baseline recorded.",
        mode: "recording", write_scope: "source_protected", allowed_paths: [], evidence_refs: []
      },
      following_steps: [],
      previous_state: Orchestrator::TickState.default_state(run.run_id)
    )

    assert_equal "awaiting_user_feedback", result.dig(:next_state, :phase)
    assert_empty result[:jobs]
    assert_not SpawnRequest.exists?(run_id: run.run_id, scope: "baseline.json")
  end

  it "planner cannot complete with pending acceptance criteria" do
    workspace = Workspace.create!(name: "turn-context-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s)
    run = Run.create!(
      workspace: workspace, run_id: "turn-context-#{SecureRandom.hex(4)}", task: "Verify completion",
      target_root: Rails.root.to_s, launcher_variant: "codex", status: "running"
    )
    AcceptanceCriterion.create!(
      run_id: run.run_id, key: "proof", status: "pending", content: "End-to-end proof is required."
    )

    error = assert_raises(ArgumentError) do
      Orchestrator::Turn.run_planner_turn(
        run_id: run.run_id, summary: "Finished.", next_step: nil, following_steps: [],
        previous_state: Orchestrator::TickState.default_state(run.run_id)
      )
    end

    assert_includes error.message, "proof"
  end

  it "rejects a planner handoff that leaves an unresolved active branch" do
    workspace = Workspace.create!(name: "turn-branch-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s)
    run = Run.create!(
      workspace:, run_id: "turn-branch-#{SecureRandom.hex(4)}", task: "Keep one branch active",
      target_root: Rails.root.to_s, launcher_variant: "codex", status: "running", active_branch_key: "baseline"
    )
    run.acceptance_criteria.create!(key: "baseline", status: "in_progress", content: "Baseline measured")
    run.acceptance_criteria.create!(key: "bottlenecks", status: "pending", content: "Bottlenecks measured")

    error = assert_raises(ArgumentError) do
      Orchestrator::Turn.run_planner_turn(
        run_id: run.run_id, summary: "Skip ahead.",
        next_step: {
          owner: "worker", artifact: "verify-bottlenecks.md", success_check: "Confirm bottlenecks.",
          mode: "verification", write_scope: "source_protected", allowed_paths: [], evidence_refs: [],
          addresses_criteria: [ "bottlenecks" ]
        },
        following_steps: [], previous_state: Orchestrator::TickState.default_state(run.run_id)
      )
    end

    assert_includes error.message, "Cannot leave active acceptance branch baseline"
  end
end

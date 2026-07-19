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

    assert_equal "blocked_on_user", result.dig(:next_state, :phase)
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
        mode: "recording", write_scope: "artifact_only", allowed_paths: [], evidence_refs: []
      },
      following_steps: [],
      previous_state: Orchestrator::TickState.default_state(run.run_id)
    )

    assert_equal "blocked_on_user", result.dig(:next_state, :phase)
    assert_empty result[:jobs]
    assert_not SpawnRequest.exists?(run_id: run.run_id, scope: "baseline.json")
  end

  it "planner cannot complete with pending acceptance criteria" do
    workspace = Workspace.create!(name: "turn-context-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s)
    run = Run.create!(
      workspace: workspace, run_id: "turn-context-#{SecureRandom.hex(4)}", task: "Verify completion",
      target_root: Rails.root.to_s, launcher_variant: "codex", status: "running"
    )
    RunContextEntry.create!(
      run_id: run.run_id, entry_key: "proof", kind: "acceptance_criterion", status: "pending",
      content: "End-to-end proof is required.", created_by: "planner"
    )

    error = assert_raises(ArgumentError) do
      Orchestrator::Turn.run_planner_turn(
        run_id: run.run_id, summary: "Finished.", next_step: nil, following_steps: [],
        previous_state: Orchestrator::TickState.default_state(run.run_id)
      )
    end

    assert_includes error.message, "proof"
  end
end

require "rails_helper"

RSpec.describe Orchestrator::PlanApprovalQuestion do
  it "builds a question whose context carries the verbatim task, the criteria tree, diagnosis findings, and the proposed step" do
    workspace = Workspace.create!(name: "plan-approval-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s)
    run = workspace.runs.create!(
      run_id: "plan-approval-#{SecureRandom.hex(4)}", task: "Distinctive-verbatim-task-text-xyz",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running",
      worktree_name: "plan-approval-a1b2", branch_name: "workflow/plan-approval-a1b2"
    )
    AcceptanceCriterion.create!(run_id: run.run_id, key: "distinctive-criterion", status: "pending", content: "Distinctive criterion content")
    request = run.spawn_requests.create!(
      asked_by: "worker", scope: "workflow-plan.md", text: "Choose the next step.",
      requested_role: "planner", priority: "blocking", status: "fulfilled", fulfilled_by: "planner_decision_job"
    )
    decision = PlannerDecision.create!(run:, spawn_request: request, status: "running")
    run.step_attempts.create!(
      attempt_id: SecureRandom.uuid, lineage_key: "diagnose-it", mode: "diagnosis", outcome: "done",
      result: "[DONE] Distinctive diagnosis finding text.", spawn_request_id: request.request_id
    )
    RunContextEntry.create!(
      run_id: run.run_id, entry_key: "diagnosis-findings-diagnose-it", kind: "fact", status: "confirmed",
      content: "Distinctive structured findings content.", created_by: "worker", evidence_ref: "diagnose-it"
    )
    next_step = {
      artifact: "fix.md", mode: "implementation", write_scope: "scoped_changes",
      allowed_paths: [ "app/models/example.rb" ], addresses_criteria: [ "distinctive-criterion" ],
      success_check: "Distinctive success check text."
    }

    question = described_class.ask!(decision:, next_step:)

    expect(question.context).to include("Distinctive-verbatim-task-text-xyz")
    expect(question.context).to include("distinctive-criterion")
    expect(question.context).to include("Distinctive criterion content")
    expect(question.context).to include("Distinctive diagnosis finding text")
    expect(question.context).to include("Distinctive structured findings content")
    expect(question.context).to include("fix.md")
    expect(question.context).to include("app/models/example.rb")
    expect(question.context).to include("Distinctive success check text")
    expect(question.tags).to eq([ "plan-approval" ])
  end

  it "truncates long values at the declared constants" do
    workspace = Workspace.create!(name: "plan-approval-truncate-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s)
    run = workspace.runs.create!(
      run_id: "plan-approval-truncate-#{SecureRandom.hex(4)}", task: "a" * 10_000,
      target_root: workspace.root_path, launcher_variant: "claude", status: "running",
      worktree_name: "plan-approval-truncate-a1b2", branch_name: "workflow/plan-approval-truncate-a1b2"
    )
    request = run.spawn_requests.create!(
      asked_by: "worker", scope: "workflow-plan.md", text: "Choose the next step.",
      requested_role: "planner", priority: "blocking", status: "fulfilled", fulfilled_by: "planner_decision_job"
    )
    decision = PlannerDecision.create!(run:, spawn_request: request, status: "running")
    run.step_attempts.create!(
      attempt_id: SecureRandom.uuid, lineage_key: "diagnose-it", mode: "diagnosis", outcome: "done",
      result: "b" * 10_000, spawn_request_id: request.request_id
    )
    next_step = { artifact: "fix.md", mode: "implementation", write_scope: "scoped_changes", allowed_paths: [], addresses_criteria: [], success_check: "check" }

    question = described_class.ask!(decision:, next_step:)

    refute_includes question.context, "a" * (described_class::TASK_LIMIT + 1)
    refute_includes question.context, "b" * (described_class::DIAGNOSIS_LIMIT + 1)
    assert_includes question.context, "a" * described_class::TASK_LIMIT
    assert_includes question.context, "b" * described_class::DIAGNOSIS_LIMIT
  end

  describe ".applicable?" do
    it "is false for a diagnosis step" do
      run = Workspace.create!(name: "plan-approval-applicable-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s).runs.create!(
        run_id: "plan-approval-applicable-#{SecureRandom.hex(4)}", task: "Task", target_root: Rails.root.to_s,
        launcher_variant: "claude", status: "running", worktree_name: "applicable-a1b2", branch_name: "workflow/applicable-a1b2"
      )

      expect(described_class.send(:applicable?, run:, next_step: { write_scope: "source_protected" })).to be(false)
    end
  end
end

require "rails_helper"

RSpec.describe McpTools::SubmitPlannerDecisionTool do
  it "delegates to PlannerDecisionSubmission using the decision from the authenticated context, not client input" do
    run, decision = build_decision

    response = described_class.call(
      outcome: "decision", summary: "Run the verification.",
      nextStep: {
        "owner" => "worker", "artifact" => "verify.md", "successCheck" => "Confirm the expected behavior.",
        "mode" => "verification", "writeScope" => "source_protected", "allowedPaths" => [], "evidenceRefs" => [],
        "addressesCriteria" => [ "existing-outcome" ]
      },
      followingSteps: [], contextRequest: nil, acceptanceCriteria: [], acceptanceUpdates: [],
      memoryEntries: [],
      server_context: { decision_id: decision.decision_id }
    )

    expect(response.error?).to be_falsey
    expect(response.structured_content[:accepted]).to be(true)
    assert_equal "completed", decision.reload.status
    assert_equal "verify.md", run.spawn_requests.open_only.find_by!(requested_role: "worker").scope
  end

  it "records a durable project memory entry alongside a decision" do
    run, decision = build_decision

    response = described_class.call(
      outcome: "decision", summary: "Run the verification.",
      nextStep: {
        "owner" => "worker", "artifact" => "verify.md", "successCheck" => "Confirm the expected behavior.",
        "mode" => "verification", "writeScope" => "source_protected", "allowedPaths" => [], "evidenceRefs" => [],
        "addressesCriteria" => [ "existing-outcome" ]
      },
      followingSteps: [], contextRequest: nil, acceptanceCriteria: [], acceptanceUpdates: [],
      memoryEntries: [
        {
          "key" => "ambient_bundler_env_leak", "kind" => "known_hazard",
          "content" => "BUNDLE_GEMFILE leaks into spawned test processes.", "evidenceRef" => "verify.md"
        }
      ],
      server_context: { decision_id: decision.decision_id }
    )

    expect(response.error?).to be_falsey
    entry = run.workspace.workspace_memory_entries.current.find_by!(entry_key: "ambient_bundler_env_leak")
    expect(entry).to have_attributes(kind: "known_hazard", recorded_by: "planner", evidence_ref: "verify.md")
  end

  it "errors when there is no authenticated planner decision capability" do
    response = described_class.call(
      outcome: "needs_stronger_model", summary: "Need more reasoning.",
      nextStep: nil, followingSteps: [], contextRequest: nil, acceptanceCriteria: [], acceptanceUpdates: [],
      memoryEntries: [],
      server_context: nil
    )

    expect(response.error?).to be(true)
  end

  it "errors when the server_context names a decision that does not exist" do
    response = described_class.call(
      outcome: "needs_stronger_model", summary: "Need more reasoning.",
      nextStep: nil, followingSteps: [], contextRequest: nil, acceptanceCriteria: [], acceptanceUpdates: [],
      memoryEntries: [],
      server_context: { decision_id: "unknown-decision" }
    )

    expect(response.error?).to be(true)
  end

  it "threads humanSummary through to the plan-approval question's text" do
    root = Dir.mktmpdir("submit-planner-decision-summary-tool")
    workspace = Workspace.create!(name: "submit-planner-decision-summary-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "submit-planner-decision-summary-#{SecureRandom.hex(4)}", task: "Exercise humanSummary",
      target_root: root, launcher_variant: "claude", status: "running",
      worktree_name: "summary-a1b2", branch_name: "workflow/summary-a1b2"
    )
    request = run.spawn_requests.create!(
      asked_by: "worker", scope: "workflow-plan.md", text: "Choose the next step.",
      requested_role: "planner", priority: "blocking"
    )
    AcceptanceCriterion.create!(run_id: run.run_id, key: "cache-lookups", status: "pending", content: "Cache lookups instead of hitting the database.")
    decision = PlannerDecision.create!(run:, spawn_request: request, status: "running")

    response = described_class.call(
      outcome: "decision", summary: "Implement the fix.",
      nextStep: {
        "owner" => "worker", "artifact" => "fix.md", "successCheck" => "Confirm the fix works.",
        "mode" => "implementation", "writeScope" => "scoped_changes", "allowedPaths" => [ "app/models/example.rb" ],
        "evidenceRefs" => [ "diagnosis.md" ], "addressesCriteria" => [ "cache-lookups" ],
        "humanSummary" => "We're adding a cache column so repeated lookups don't hit the database every time."
      },
      followingSteps: [], contextRequest: nil, acceptanceCriteria: [], acceptanceUpdates: [],
      memoryEntries: [],
      server_context: { decision_id: decision.decision_id }
    )

    expect(response.error?).to be_falsey
    question = UserQuestion.plan_approval.find_by!(run_id: run.run_id)
    expect(question.text).to start_with("We're adding a cache column")
  end

  def build_decision
    root = Dir.mktmpdir("submit-planner-decision-tool")
    workspace = Workspace.create!(name: "submit-planner-decision-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "submit-planner-decision-#{SecureRandom.hex(4)}", task: "Exercise the tool",
      target_root: root, launcher_variant: "claude", status: "running"
    )
    request = run.spawn_requests.create!(
      asked_by: "worker", scope: "workflow-plan.md", text: "Choose the next step.",
      requested_role: "planner", priority: "blocking"
    )
    AcceptanceCriterion.create!(
      run_id: run.run_id, key: "existing-outcome", status: "verified",
      content: "Existing test outcome", evidence_ref: "Gemfile"
    )
    [ run, PlannerDecision.create!(run:, spawn_request: request, status: "running") ]
  end
end

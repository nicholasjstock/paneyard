require "rails_helper"

RSpec.describe McpTools::SubmitPlannerDecisionTool do
  after { PlannerDecisionContext.reset }

  it "delegates to PlannerDecisionSubmission using the decision from the authenticated context, not client input" do
    run, decision = build_decision
    PlannerDecisionContext.decision = decision

    response = described_class.call(
      outcome: "decision", summary: "Run the verification.",
      nextStep: {
        "owner" => "worker", "artifact" => "verify.md", "successCheck" => "Confirm the expected behavior.",
        "mode" => "verification", "writeScope" => "artifact_only", "allowedPaths" => [], "evidenceRefs" => []
      },
      followingSteps: [], contextRequest: nil, acceptanceCriteria: [], acceptanceUpdates: [],
      server_context: nil
    )

    expect(response.error?).to be_falsey
    expect(response.structured_content[:accepted]).to be(true)
    assert_equal "completed", decision.reload.status
    assert_equal "verify.md", run.spawn_requests.open_only.find_by!(requested_role: "worker").scope
  end

  it "errors when there is no authenticated planner decision capability" do
    response = described_class.call(
      outcome: "needs_stronger_model", summary: "Need more reasoning.",
      nextStep: nil, followingSteps: [], contextRequest: nil, acceptanceCriteria: [], acceptanceUpdates: [],
      server_context: nil
    )

    expect(response.error?).to be(true)
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
    RunContextEntry.create!(
      run_id: run.run_id, entry_key: "existing-outcome", kind: "acceptance_criterion", status: "verified",
      content: "Existing test outcome", evidence_ref: "Gemfile", created_by: "test"
    )
    [ run, PlannerDecision.create!(run:, spawn_request: request, status: "running") ]
  end
end

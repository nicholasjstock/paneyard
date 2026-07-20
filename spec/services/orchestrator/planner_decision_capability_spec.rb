require "rails_helper"

RSpec.describe Orchestrator::PlannerDecisionCapability do
  it "issues a token that authenticates back to the same decision" do
    decision = build_decision

    token = described_class.issue(decision)

    expect(described_class.authenticate(token)).to eq(decision)
  end

  it "rejects a tampered token" do
    decision = build_decision
    token = described_class.issue(decision)

    expect(described_class.authenticate("#{token}tampered")).to be_nil
  end

  it "rejects an unrecognized decision_id" do
    verifier = Rails.application.message_verifier("planner-decision-capability")
    token = verifier.generate({ decision_id: "unknown-decision" }, expires_in: 10.minutes)

    expect(described_class.authenticate(token)).to be_nil
  end

  def build_decision
    root = Dir.mktmpdir("planner-decision-capability")
    workspace = Workspace.create!(name: "planner-decision-capability-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "planner-decision-capability-#{SecureRandom.hex(4)}", task: "Exercise capability auth",
      target_root: root, launcher_variant: "claude", status: "running"
    )
    request = run.spawn_requests.create!(
      asked_by: "worker", scope: "workflow-plan.md", text: "Choose the next step.",
      requested_role: "planner", priority: "blocking"
    )
    PlannerDecision.create!(run:, spawn_request: request, status: "running")
  end
end

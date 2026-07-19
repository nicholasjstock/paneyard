require "rails_helper"

RSpec.describe Orchestrator::Planner do
  it "does not infer a source-specific worker role from tool names" do
    plan = Orchestrator::Planner.plan_workflow_iteration(
      task: "Fix the stalled worker", verifier_finding: "Docker worker logs stop streaming."
    )

    assert_equal "worker", plan.dig(:next_step, :owner)
  end
end

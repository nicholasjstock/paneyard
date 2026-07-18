require "rails_helper"

RSpec.describe Orchestrator::Planner do
  it "routes infrastructure findings to the infrastructure role" do
    plan = Orchestrator::Planner.plan_workflow_iteration(
      task: "Fix the stalled worker", verifier_finding: "Docker worker logs stop streaming."
    )

    assert_equal "infrastructure", plan.dig(:next_step, :owner)
  end
end

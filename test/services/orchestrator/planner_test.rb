require "test_helper"

class Orchestrator::PlannerTest < ActiveSupport::TestCase
  test "routes infrastructure findings to the infrastructure role" do
    plan = Orchestrator::Planner.plan_workflow_iteration(
      task: "Fix the stalled worker", verifier_finding: "Docker worker logs stop streaming."
    )

    assert_equal "infrastructure", plan.dig(:next_step, :owner)
  end
end

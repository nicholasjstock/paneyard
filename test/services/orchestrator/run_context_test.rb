require "test_helper"

class Orchestrator::RunContextTest < ActiveSupport::TestCase
  test "reports only pending acceptance criteria as completion blockers" do
    run_id = "context-test-#{SecureRandom.hex(4)}"
    RunContextEntry.create!(
      run_id: run_id, entry_key: "speed", kind: "acceptance_criterion", status: "verified",
      content: "Recording speed is reduced.", evidence_ref: "speed-report.md", created_by: "planner"
    )
    RunContextEntry.create!(
      run_id: run_id, entry_key: "recording", kind: "acceptance_criterion", status: "pending",
      content: "A full recording proves the change.", created_by: "planner"
    )

    snapshot = Orchestrator::RunContext.snapshot(run_id: run_id)

    assert_equal [ "recording" ], snapshot[:completion_blockers]
  end
end

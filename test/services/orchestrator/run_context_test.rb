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
    assert_equal [ "recording" ], Orchestrator::RunContext.completion_blockers(run_id: run_id)
  end

  test "returns a bounded brief by default and full content for requested keys" do
    run_id = "context-brief-#{SecureRandom.hex(4)}"
    long_content = "x" * 900
    RunContextEntry.create!(
      run_id: run_id, entry_key: "diagnosis", kind: "fact", status: "confirmed",
      content: long_content, evidence_ref: "diagnosis.md", created_by: "planner"
    )

    brief = Orchestrator::RunContext.snapshot(run_id: run_id)
    detailed = Orchestrator::RunContext.snapshot(run_id: run_id, entry_keys: [ "diagnosis" ])

    assert_equal "brief", brief[:context_mode]
    assert_equal [ "diagnosis" ], brief[:available_entry_keys]
    assert brief[:entries].first[:content].end_with?("…")
    assert_equal "selected", detailed[:context_mode]
    assert_equal long_content, detailed[:entries].first[:content]
  end
end

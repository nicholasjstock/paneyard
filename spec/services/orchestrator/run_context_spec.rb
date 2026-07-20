require "rails_helper"

RSpec.describe Orchestrator::RunContext do
  it "returns a bounded brief by default and full content for requested keys" do
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

require "rails_helper"

RSpec.describe Orchestrator::RunContext do
  it "reports only pending acceptance criteria as completion blockers" do
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

  it "persists an initial planner contract and keeps it immutable" do
    root = Dir.mktmpdir("planner-acceptance")
    workspace = Workspace.create!(name: "acceptance-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "acceptance-#{SecureRandom.hex(4)}", task: "Create the requested outcome",
      target_root: root, launcher_variant: "claude", status: "running"
    )

    described_class.apply_planner_acceptance!(
      run:, criteria: [ { key: "observable-outcome", content: "The requested outcome is positively verified." } ], updates: []
    )

    expect(described_class.completion_blockers(run_id: run.run_id)).to eq([ "observable-outcome" ])
    expect do
      described_class.apply_planner_acceptance!(
        run:, criteria: [ { key: "replacement", content: "Replace the contract." } ], updates: []
      )
    end.to raise_error(ArgumentError, /immutable/)
  end

  it "accepts planner verification only when its evidence exists inside the workspace" do
    root = Dir.mktmpdir("planner-evidence")
    workspace = Workspace.create!(name: "evidence-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "evidence-#{SecureRandom.hex(4)}", task: "Verify it",
      target_root: root, launcher_variant: "claude", status: "running"
    )
    described_class.apply_planner_acceptance!(
      run:, criteria: [ { key: "verified-result", content: "Positive evidence exists." } ], updates: []
    )

    expect do
      described_class.apply_planner_acceptance!(
        run:, criteria: [], updates: [ { key: "verified-result", status: "verified", evidence_ref: "missing.md" } ]
      )
    end.to raise_error(ArgumentError, /does not exist/)

    File.write(File.join(root, "result.md"), "positive verification")
    described_class.apply_planner_acceptance!(
      run:, criteria: [], updates: [ { key: "verified-result", status: "verified", evidence_ref: "result.md" } ]
    )
    expect(described_class.completion_blockers(run_id: run.run_id)).to be_empty
  end
end

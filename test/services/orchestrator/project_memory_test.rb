require "test_helper"

class Orchestrator::ProjectMemoryTest < ActiveSupport::TestCase
  test "supersedes a project-memory entry with the same key" do
    workspace = Workspace.create!(name: "memory-#{SecureRandom.hex(4)}", root_path: Rails.root.join("tmp", SecureRandom.hex(4)).to_s)
    run = Run.create!(
      workspace: workspace, run_id: "memory-run-#{SecureRandom.hex(4)}", task: "Memory test",
      target_root: workspace.root_path, launcher_variant: "codex", status: "running"
    )

    first = Orchestrator::ProjectMemory.record!(
      run_id: run.run_id, entry_key: "test-command", kind: "convention", content: "Run command A.",
      evidence_ref: "report-a.md", recorded_by: "planner"
    )
    second = Orchestrator::ProjectMemory.record!(
      run_id: run.run_id, entry_key: "test-command", kind: "convention", content: "Run command B.",
      evidence_ref: "report-b.md", recorded_by: "planner"
    )

    entries = Orchestrator::ProjectMemory.snapshot(run_id: run.run_id)[:entries]

    assert_equal "superseded", first.reload.status
    assert_equal first.id, second.supersedes_id
    assert_equal [ "Run command B." ], entries.map { |entry| entry[:content] }
  end

  test "returns a bounded brief and supports key-based detail retrieval" do
    workspace = Workspace.create!(name: "memory-brief-#{SecureRandom.hex(4)}", root_path: Rails.root.join("tmp", SecureRandom.hex(4)).to_s)
    run = Run.create!(
      workspace: workspace, run_id: "memory-brief-run-#{SecureRandom.hex(4)}", task: "Memory test",
      target_root: workspace.root_path, launcher_variant: "codex", status: "running"
    )
    long_content = "x" * 900
    Orchestrator::ProjectMemory.record!(
      run_id: run.run_id, entry_key: "long-rule", kind: "operational_rule", content: long_content,
      evidence_ref: "rule.md", recorded_by: "planner"
    )

    brief = Orchestrator::ProjectMemory.snapshot(run_id: run.run_id)
    detailed = Orchestrator::ProjectMemory.snapshot(run_id: run.run_id, entry_keys: [ "long-rule" ])

    assert brief[:entries].first[:content].end_with?("…")
    assert_equal long_content, detailed[:entries].first[:content]
  end
end

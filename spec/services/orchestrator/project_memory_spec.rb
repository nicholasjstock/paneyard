require "rails_helper"

RSpec.describe Orchestrator::ProjectMemory do
  it "supersedes a project-memory entry with the same key" do
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

  it "always includes the primary dev-environment fact in the brief, ahead of unrelated hazards that sort earlier alphabetically" do
    workspace = Workspace.create!(name: "memory-priority-#{SecureRandom.hex(4)}", root_path: Rails.root.join("tmp", SecureRandom.hex(4)).to_s)
    run = Run.create!(
      workspace: workspace, run_id: "memory-priority-run-#{SecureRandom.hex(4)}", task: "Memory test",
      target_root: workspace.root_path, launcher_variant: "codex", status: "running"
    )
    # Seed enough known_hazard/architecture entries (all sorting before
    # "operational_rule" alphabetically, and before "dev-environment"
    # within operational_rule) to overflow DEFAULT_BRIEF_ENTRY_LIMIT on
    # their own -- this is the exact shape of the real bug: alphabetically
    # earlier, less load-bearing facts crowding out the one fact every
    # worker actually needs to get started.
    9.times do |i|
      Orchestrator::ProjectMemory.record!(
        run_id: run.run_id, entry_key: "aaa-hazard-#{i}", kind: "known_hazard",
        content: "Hazard #{i}.", evidence_ref: "hazard.md", recorded_by: "planner"
      )
    end
    Orchestrator::ProjectMemory.record!(
      run_id: run.run_id, entry_key: Orchestrator::ProjectInitTrigger::PRIMARY_ENTRY_KEY, kind: "operational_rule",
      content: "Run bin/dev from project root.", evidence_ref: "bin/dev", recorded_by: "project_init"
    )

    brief = Orchestrator::ProjectMemory.snapshot(run_id: run.run_id)

    assert_equal "dev-environment", brief[:entries].first[:key]
  end

  it "prioritizes operational_rule over known_hazard and architecture in the brief" do
    workspace = Workspace.create!(name: "memory-kind-#{SecureRandom.hex(4)}", root_path: Rails.root.join("tmp", SecureRandom.hex(4)).to_s)
    run = Run.create!(
      workspace: workspace, run_id: "memory-kind-run-#{SecureRandom.hex(4)}", task: "Memory test",
      target_root: workspace.root_path, launcher_variant: "codex", status: "running"
    )
    Orchestrator::ProjectMemory.record!(
      run_id: run.run_id, entry_key: "aaa-architecture", kind: "architecture",
      content: "Architecture note.", evidence_ref: "a.md", recorded_by: "planner"
    )
    Orchestrator::ProjectMemory.record!(
      run_id: run.run_id, entry_key: "zzz-operational-rule", kind: "operational_rule",
      content: "How to run tests.", evidence_ref: "b.md", recorded_by: "planner"
    )

    brief = Orchestrator::ProjectMemory.snapshot(run_id: run.run_id)

    assert_equal "zzz-operational-rule", brief[:entries].first[:key]
  end

  it "prefers the most recently confirmed entry within the same kind" do
    workspace = Workspace.create!(name: "memory-recency-#{SecureRandom.hex(4)}", root_path: Rails.root.join("tmp", SecureRandom.hex(4)).to_s)
    run = Run.create!(
      workspace: workspace, run_id: "memory-recency-run-#{SecureRandom.hex(4)}", task: "Memory test",
      target_root: workspace.root_path, launcher_variant: "codex", status: "running"
    )
    older = Orchestrator::ProjectMemory.record!(
      run_id: run.run_id, entry_key: "aaa-older", kind: "known_hazard",
      content: "Older hazard.", evidence_ref: "a.md", recorded_by: "planner"
    )
    older.update!(created_at: 1.hour.ago)
    Orchestrator::ProjectMemory.record!(
      run_id: run.run_id, entry_key: "zzz-newer", kind: "known_hazard",
      content: "Newer hazard.", evidence_ref: "b.md", recorded_by: "planner"
    )

    brief = Orchestrator::ProjectMemory.snapshot(run_id: run.run_id)

    assert_equal "zzz-newer", brief[:entries].first[:key]
  end

  it "returns a bounded brief and supports key-based detail retrieval" do
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

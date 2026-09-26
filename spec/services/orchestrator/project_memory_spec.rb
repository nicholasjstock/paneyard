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
      evidence_ref: "report-a.md", recorded_by: "session"
    )
    second = Orchestrator::ProjectMemory.record!(
      run_id: run.run_id, entry_key: "test-command", kind: "convention", content: "Run command B.",
      evidence_ref: "report-b.md", recorded_by: "session"
    )

    entries = Orchestrator::ProjectMemory.snapshot(run_id: run.run_id)[:entries]

    assert_equal "superseded", first.reload.status
    assert_equal first.id, second.supersedes_id
    assert_equal [ "Run command B." ], entries.map { |entry| entry[:content] }
  end

  it "always includes the primary dev-environment fact in the brief, ahead of newer unrelated hazards" do
    workspace = Workspace.create!(name: "memory-priority-#{SecureRandom.hex(4)}", root_path: Rails.root.join("tmp", SecureRandom.hex(4)).to_s)
    run = Run.create!(
      workspace: workspace, run_id: "memory-priority-run-#{SecureRandom.hex(4)}", task: "Memory test",
      target_root: workspace.root_path, launcher_variant: "codex", status: "running"
    )
    # Record the primary entry first (oldest), then seed more known_hazard
    # entries than DEFAULT_BRIEF_ENTRY_LIMIT after it, so recency alone
    # would both rank it last and push it out of a plain top-N-by-created_at
    # brief -- this is the exact shape of the real bug: newer, less
    # load-bearing facts crowding out the one fact every worker actually
    # needs to get started.
    Orchestrator::ProjectMemory.record!(
      run_id: run.run_id, entry_key: Orchestrator::ProjectMemory::PRIMARY_ENTRY_KEY, kind: "operational_rule",
      content: "Run bin/dev from project root.", evidence_ref: "bin/dev", recorded_by: "session"
    )
    9.times do |i|
      Orchestrator::ProjectMemory.record!(
        run_id: run.run_id, entry_key: "aaa-hazard-#{i}", kind: "known_hazard",
        content: "Hazard #{i}.", evidence_ref: "hazard.md", recorded_by: "session"
      )
    end

    brief = Orchestrator::ProjectMemory.snapshot(run_id: run.run_id)

    assert_equal "dev-environment", brief[:entries].first[:key]
  end

  it "orders the brief by recency alone, not by kind" do
    workspace = Workspace.create!(name: "memory-kind-#{SecureRandom.hex(4)}", root_path: Rails.root.join("tmp", SecureRandom.hex(4)).to_s)
    run = Run.create!(
      workspace: workspace, run_id: "memory-kind-run-#{SecureRandom.hex(4)}", task: "Memory test",
      target_root: workspace.root_path, launcher_variant: "codex", status: "running"
    )
    rule = Orchestrator::ProjectMemory.record!(
      run_id: run.run_id, entry_key: "old-operational-rule", kind: "operational_rule",
      content: "An old rule.", evidence_ref: "a.md", recorded_by: "session"
    )
    rule.update!(created_at: 1.hour.ago)
    Orchestrator::ProjectMemory.record!(
      run_id: run.run_id, entry_key: "new-convention", kind: "convention",
      content: "A newer convention.", evidence_ref: "b.md", recorded_by: "session"
    )

    brief = Orchestrator::ProjectMemory.snapshot(run_id: run.run_id)

    assert_equal "new-convention", brief[:entries].first[:key]
  end

  it "guarantees the primary dev-environment fact a brief slot in addition to the entry limit, not counted against it" do
    workspace = Workspace.create!(name: "memory-primary-slot-#{SecureRandom.hex(4)}", root_path: Rails.root.join("tmp", SecureRandom.hex(4)).to_s)
    run = Run.create!(
      workspace: workspace, run_id: "memory-primary-slot-run-#{SecureRandom.hex(4)}", task: "Memory test",
      target_root: workspace.root_path, launcher_variant: "codex", status: "running"
    )
    Orchestrator::ProjectMemory::DEFAULT_BRIEF_ENTRY_LIMIT.times do |i|
      Orchestrator::ProjectMemory.record!(
        run_id: run.run_id, entry_key: "rule-#{i}", kind: "operational_rule",
        content: "Rule #{i}.", evidence_ref: "r.md", recorded_by: "session"
      )
    end
    Orchestrator::ProjectMemory.record!(
      run_id: run.run_id, entry_key: Orchestrator::ProjectMemory::PRIMARY_ENTRY_KEY, kind: "operational_rule",
      content: "Run bin/dev from project root.", evidence_ref: "bin/dev", recorded_by: "session"
    )

    brief = Orchestrator::ProjectMemory.snapshot(run_id: run.run_id)

    assert_equal Orchestrator::ProjectMemory::DEFAULT_BRIEF_ENTRY_LIMIT + 1, brief[:entries].length
    assert_equal "dev-environment", brief[:entries].first[:key]
  end

  it "prefers the most recently confirmed entry within the same kind" do
    workspace = Workspace.create!(name: "memory-recency-#{SecureRandom.hex(4)}", root_path: Rails.root.join("tmp", SecureRandom.hex(4)).to_s)
    run = Run.create!(
      workspace: workspace, run_id: "memory-recency-run-#{SecureRandom.hex(4)}", task: "Memory test",
      target_root: workspace.root_path, launcher_variant: "codex", status: "running"
    )
    older = Orchestrator::ProjectMemory.record!(
      run_id: run.run_id, entry_key: "aaa-older", kind: "known_hazard",
      content: "Older hazard.", evidence_ref: "a.md", recorded_by: "session"
    )
    older.update!(created_at: 1.hour.ago)
    Orchestrator::ProjectMemory.record!(
      run_id: run.run_id, entry_key: "zzz-newer", kind: "known_hazard",
      content: "Newer hazard.", evidence_ref: "b.md", recorded_by: "session"
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
      evidence_ref: "rule.md", recorded_by: "session"
    )

    brief = Orchestrator::ProjectMemory.snapshot(run_id: run.run_id)
    detailed = Orchestrator::ProjectMemory.snapshot(run_id: run.run_id, entry_keys: [ "long-rule" ])

    assert brief[:entries].first[:content].end_with?("…")
    assert_equal long_content, detailed[:entries].first[:content]
  end
end

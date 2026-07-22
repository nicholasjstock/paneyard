require "rails_helper"

RSpec.describe McpTools::ChaperoneStateTool do
  it "returns structured state instead of raising when a step attempt's scope is a nested workspace path" do
    root = Dir.mktmpdir("chaperone-state-tool")
    workspace = Workspace.create!(name: "chaperone-state-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "run-#{SecureRandom.hex(4)}", task: "Instrument the demo script",
      target_root: root, launcher_variant: "claude", status: "running"
    )
    request = run.spawn_requests.create!(
      asked_by: "planner", scope: "front/scripts/record-demo.ts",
      text: "Execution mode: implementation. Instrument timing.",
      requested_role: "worker", priority: "blocking", status: "fulfilled",
      fulfilled_worker_id: SecureRandom.uuid, lineage_key: "implement-tier2-instrumentation"
    )
    attempt = StepAttempt.create!(
      run_id: run.run_id, spawn_request: request, worker_id: request.fulfilled_worker_id,
      lineage_key: request.lineage_key, mode: "implementation",
      outcome: "failed", result: "Worker exited before completing its handoff.",
      evidence_outcome: nil, evidence_citations: []
    )
    review, = ChaperoneReview.issue!(
      run:, lineage_key: request.lineage_key, step_attempt_ids: [ attempt.attempt_id ]
    )

    response = described_class.call(server_context: { review_id: review.id })

    assert_equal request.lineage_key, response.structured_content[:review][:lineageKey]
    assert_equal 1, response.structured_content[:attempts].length
    assert_equal "front/scripts/record-demo.ts", response.structured_content[:attempts].first[:artifact]
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  it "lists every prior stop-replan blockerKey for the lineage so the chaperone can reuse one instead of minting a fresh slug" do
    root = Dir.mktmpdir("chaperone-state-tool")
    workspace = Workspace.create!(name: "chaperone-state-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "run-#{SecureRandom.hex(4)}", task: "Instrument the demo script",
      target_root: root, launcher_variant: "claude", status: "running"
    )
    run.spawn_requests.create!(
      asked_by: "chaperone", scope: Orchestrator::Turn::PLANNER_FOLLOWUP_SCOPE, text: "Repair replan.",
      requested_role: "planner", priority: "blocking", lineage_key: "criterion:phone-flow", model_tier: "small",
      context: "Chaperone stopped the current retry: Docker is unavailable.",
      tags: %w[planner chaperone stopped_retry replan blocker:docker-unavailable]
    )
    request = run.spawn_requests.create!(
      asked_by: "planner", scope: "recording.md", text: "Record the flow.", requested_role: "infrastructure",
      priority: "blocking", lineage_key: "criterion:phone-flow", execution_mode: "recording",
      write_scope: "source_protected", allowed_paths: []
    )
    attempt = StepAttempt.create!(
      run:, spawn_request: request, worker_id: SecureRandom.uuid, lineage_key: "criterion:phone-flow",
      mode: "recording", outcome: "blocked", result: "Docker is still unavailable under a different name."
    )
    review, = ChaperoneReview.issue!(run:, lineage_key: "criterion:phone-flow", step_attempt_ids: [ attempt.attempt_id ])

    response = described_class.call(server_context: { review_id: review.id })

    prior_blockers = response.structured_content[:priorBlockers]
    assert_equal 1, prior_blockers.length
    assert_equal "docker-unavailable", prior_blockers.first[:blockerKey]
    assert_equal "small", prior_blockers.first[:tier]
    assert prior_blockers.first[:summary].include?("Docker is unavailable")
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end
end

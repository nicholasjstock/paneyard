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
end

require "test_helper"

class McpTools::WorkerTurnToolTest < ActiveSupport::TestCase
  test "binds a handoff to the sole active worker when the model invents a nickname" do
    root = Dir.mktmpdir("worker-turn-identity")
    workspace = Workspace.create!(name: "worker-turn-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "worker-turn-#{SecureRandom.hex(4)}", task: "Verify performance",
      target_root: root, launcher_variant: "claude", status: "running"
    )
    worker = run.workers.create!(
      worker_id: SecureRandom.uuid, role: "worker", nickname: "worker-7", reason: "Verify it.",
      scope: "performance-verification.md", status: "running", pid: 12_345, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/worker-7.prompt").to_s,
      log_path: Rails.root.join("tmp/worker-7.log").to_s,
      last_message_path: Rails.root.join("tmp/worker-7.last").to_s,
      env_path: Rails.root.join("tmp/worker-7.env").to_s
    )

    McpTools::WorkerTurnTool.call(
      runId: run.run_id, role: "worker", nickname: "perf-verifier", scope: "performance-verification",
      task: "Verify it", result: "[BLOCKED] Backend did not start.", evidenceOutcome: "blocked",
      evidenceCitations: [ "backend initialization failed" ], server_context: {}
    )

    assert worker.reload.handoff_completed_at
    request = run.spawn_requests.order(:created_at).last
    assert_includes request.context, "Worker worker-7"
    assert_includes request.context, "scope performance-verification.md"
    assert_includes request.tags, "evidence-blocked"
  end
end

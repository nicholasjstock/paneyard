require "rails_helper"

RSpec.describe McpTools::WorkerTurnTool do
  it "binds a handoff to the sole active worker when the model invents a nickname" do
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

  it "uses the authenticated worker even when caller identity fields name another worker" do
    root = Dir.mktmpdir("worker-turn-capability")
    workspace = Workspace.create!(name: "worker-capability-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "worker-capability-#{SecureRandom.hex(4)}", task: "Verify identity",
      target_root: root, launcher_variant: "claude", status: "running"
    )
    authenticated = create_worker(run, "worker-auth", "auth-report.md")
    other = create_worker(run, "worker-other", "other-report.md")

    described_class.call(
      runId: run.run_id, role: "worker", nickname: other.nickname, scope: other.scope,
      task: "Verify identity", result: "[DONE] Authenticated result.",
      server_context: { worker_id: authenticated.worker_id }
    )

    expect(authenticated.reload.handoff_completed_at).to be_present
    expect(other.reload.handoff_completed_at).to be_nil
  end

  def create_worker(run, nickname, scope)
    run.workers.create!(
      worker_id: SecureRandom.uuid, role: "worker", nickname:, reason: "Verify it.", scope:,
      status: "running", pid: 12_345, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/#{nickname}.prompt").to_s,
      log_path: Rails.root.join("tmp/#{nickname}.log").to_s,
      last_message_path: Rails.root.join("tmp/#{nickname}.last").to_s,
      env_path: Rails.root.join("tmp/#{nickname}.env").to_s
    )
  end
end

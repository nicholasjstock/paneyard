require "rails_helper"

RSpec.describe McpTools::ReportFailedApproachTool do
  it "records a proposed candidate for an authenticated worker, deriving lineage_key from its spawn request" do
    run, worker, request = create_run_worker_and_request(role: "worker")

    response = described_class.call(
      runId: run.run_id, approach: "Ran `npm start` from the repo root.",
      reason: "There is no package.json there; the frontend lives under front/.",
      nextApproach: "Try `npm start` from front/ instead.",
      server_context: { worker_id: worker.worker_id }
    )

    expect(response.error?).to be_falsey
    candidate = MemoryCandidate.find_by!(worker_id: worker.worker_id)
    expect(candidate.status).to eq("proposed")
    expect(candidate.role).to eq("worker")
    expect(candidate.lineage_key).to eq(request.lineage_key)
    expect(candidate.reason).to include("front/")
    expect(candidate.next_approach).to include("front/")
  end

  it "works for any worker role, not only worker" do
    run, worker, = create_run_worker_and_request(role: "project_init")

    response = described_class.call(
      runId: run.run_id, approach: "Assumed bin/dev starts everything.",
      reason: "bin/dev does not exist in this repository.",
      server_context: { worker_id: worker.worker_id }
    )

    expect(response.error?).to be_falsey
    candidate = MemoryCandidate.find_by!(worker_id: worker.worker_id)
    expect(candidate.role).to eq("project_init")
  end

  it "rejects an unauthenticated caller outside test-mode's server_context escape hatch" do
    run, = create_run_worker_and_request(role: "worker")

    response = described_class.call(
      runId: run.run_id, approach: "Tried X.", reason: "It failed.",
      server_context: { worker_id: "unknown" }
    )

    expect(response.error?).to be(true)
    expect(MemoryCandidate.where(run_id: run.run_id)).to be_empty
  end

  def create_run_worker_and_request(role:)
    root = Dir.mktmpdir("report-failed-approach")
    workspace = Workspace.create!(name: "report-failed-approach-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "report-failed-approach-#{SecureRandom.hex(4)}", task: "Exercise report_failed_approach",
      target_root: root, launcher_variant: "claude", status: "running"
    )
    worker = run.workers.create!(
      worker_id: SecureRandom.uuid, role: role, nickname: "#{role}-#{SecureRandom.hex(2)}", reason: "test",
      scope: "task.md", status: "running", pid: 99_997, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.prompt").to_s,
      log_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.log").to_s,
      last_message_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.last").to_s,
      env_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.env").to_s
    )
    request = run.spawn_requests.create!(
      asked_by: "orchestrator", scope: "task.md", text: "Do the task.", requested_role: role,
      priority: "blocking", lineage_key: "#{role}-lineage", status: "fulfilled", fulfilled_worker_id: worker.worker_id
    )
    [ run, worker, request ]
  end
end

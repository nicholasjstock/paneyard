require "rails_helper"

RSpec.describe McpTools::SubmitAcceptanceVerificationTool do
  it "verifies a criterion for an authenticated verifier worker citing fresh evidence" do
    run, worker = build_ready_criterion(evidence_ref: "claimed.md")
    Orchestrator::ArtifactStore.write(run.target_root, run.run_id, "verifier-fresh.md", "Reproduced independently.")

    response = described_class.call(
      runId: run.run_id, criterionKey: "outcome", outcome: "verified", evidenceRef: "verifier-fresh.md",
      summary: "Reran the measurement myself.", server_context: { worker_id: worker.worker_id }
    )

    expect(response.error?).to be_falsey
    criterion = run.acceptance_criteria.find_by!(key: "outcome")
    expect(criterion.status).to eq("verified")
    expect(criterion.evidence_ref).to eq("verifier-fresh.md")
  end

  it "rejects verifying with the same evidence the criterion already carries" do
    run, worker = build_ready_criterion(evidence_ref: "claimed.md")

    response = described_class.call(
      runId: run.run_id, criterionKey: "outcome", outcome: "verified", evidenceRef: "claimed.md",
      summary: "Looks right.", server_context: { worker_id: worker.worker_id }
    )

    expect(response.error?).to be(true)
    expect(run.acceptance_criteria.find_by!(key: "outcome").status).to eq("ready_for_verification")
  end

  it "sends a rejected outcome back to blocked" do
    run, worker = build_ready_criterion(evidence_ref: "claimed.md")

    response = described_class.call(
      runId: run.run_id, criterionKey: "outcome", outcome: "rejected", evidenceRef: nil,
      summary: "Could not reproduce the claimed result.", server_context: { worker_id: worker.worker_id }
    )

    expect(response.error?).to be_falsey
    expect(run.acceptance_criteria.find_by!(key: "outcome").status).to eq("blocked")
  end

  it "rejects a caller that is not the authorized verifier for this criterion" do
    run, = build_ready_criterion(evidence_ref: "claimed.md")
    other_worker = run.workers.create!(
      worker_id: SecureRandom.uuid, role: "verifier", nickname: "verifier-other", reason: "test",
      scope: "acceptance-verify-other-key", status: "running", pid: 99_996, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.prompt").to_s,
      log_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.log").to_s,
      last_message_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.last").to_s,
      env_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.env").to_s
    )

    response = described_class.call(
      runId: run.run_id, criterionKey: "outcome", outcome: "verified", evidenceRef: "fresh.md",
      summary: "n/a", server_context: { worker_id: other_worker.worker_id }
    )

    expect(response.error?).to be(true)
    expect(run.acceptance_criteria.find_by!(key: "outcome").status).to eq("ready_for_verification")
  end

  it "rejects a non-verifier worker even if it names the right scope" do
    run, = build_ready_criterion(evidence_ref: "claimed.md")
    imposter = run.workers.create!(
      worker_id: SecureRandom.uuid, role: "worker", nickname: "worker-imposter", reason: "test",
      scope: "acceptance-verify-outcome", status: "running", pid: 99_995, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.prompt").to_s,
      log_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.log").to_s,
      last_message_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.last").to_s,
      env_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.env").to_s
    )

    response = described_class.call(
      runId: run.run_id, criterionKey: "outcome", outcome: "verified", evidenceRef: "fresh.md",
      summary: "n/a", server_context: { worker_id: imposter.worker_id }
    )

    expect(response.error?).to be(true)
  end

  def build_ready_criterion(evidence_ref:)
    root = Dir.mktmpdir("submit-acceptance-verification")
    workspace = Workspace.create!(name: "submit-acceptance-verification-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "submit-acceptance-verification-#{SecureRandom.hex(4)}", task: "Exercise the tool",
      target_root: root, launcher_variant: "claude", status: "running"
    )
    Orchestrator::ArtifactStore.write(run.target_root, run.run_id, evidence_ref, "Claimed result.")
    Orchestrator::AcceptanceCriteria.apply!(
      run: run, criteria: [ { key: "outcome", content: "Demo is faster.", parent_key: nil } ], updates: []
    )
    Orchestrator::AcceptanceCriteria.apply!(
      run: run, criteria: [], updates: [ { key: "outcome", status: "ready_for_verification", evidence_ref: evidence_ref } ]
    )
    worker = run.workers.create!(
      worker_id: SecureRandom.uuid, role: "verifier", nickname: "verifier-1", reason: "test",
      scope: "acceptance-verify-outcome", status: "running", pid: 99_998, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.prompt").to_s,
      log_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.log").to_s,
      last_message_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.last").to_s,
      env_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.env").to_s
    )
    [ run, worker ]
  end
end

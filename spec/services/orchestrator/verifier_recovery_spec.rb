require "rails_helper"

RSpec.describe Orchestrator::VerifierRecovery do
  it "re-requests a real verifier instead of triggering a chaperone after a failed verifier attempt" do
    run, criterion = create_run_with_criterion
    attempt = create_failed_attempt(run, criterion)

    result = described_class.call(attempt)

    expect(result).to eq(:requeued)
    fresh = run.spawn_requests.where(requested_role: "verifier", status: "open").sole
    expect(fresh.scope).to eq("acceptance-verify-#{criterion.key}")
    expect(fresh.lineage_key).to eq("acceptance:#{criterion.key}")
    expect(fresh.context).to include("mcp__workflow__submit_acceptance_verification")
    expect(ChaperoneReview.where(run_id: run.run_id)).to be_empty
    expect(run.reload.phase).to eq("planning")
  end

  it "does not stack a duplicate verifier request when one is already open" do
    run, criterion = create_run_with_criterion
    attempt = create_failed_attempt(run, criterion)
    described_class.call(attempt)

    described_class.call(create_failed_attempt(run, criterion))

    expect(run.spawn_requests.where(requested_role: "verifier", status: "open").count).to eq(1)
  end

  it "escalates to a blocking user question after repeated verifier failures" do
    run, criterion = create_run_with_criterion
    attempts = Array.new(described_class::MAX_VERIFIER_ATTEMPTS) { create_failed_attempt(run, criterion) }

    result = described_class.call(attempts.last)

    expect(result).to eq(:escalated)
    question = run.user_questions.open_only.where(priority: "blocking").sole
    expect(question.text).to include(criterion.key)
    expect(question.asked_by).to eq("verifier_recovery")
    expect(run.reload.phase).to eq("awaiting_user_feedback")
    expect(run.spawn_requests.where(requested_role: "verifier", status: "open")).to be_empty
  end

  it "recovers a planner-renamed verification retry via its provenance edge to the criterion" do
    run, criterion = create_run_with_criterion
    worker = create_worker(run, criterion, status: "stopped")
    request = run.spawn_requests.create!(
      asked_by: "planner", requested_role: "worker", scope: "redo-verification.md",
      lineage_key: "retry-the-verification", status: "fulfilled", fulfilled_worker_id: worker.worker_id,
      text: "Verify it again.", priority: "blocking", execution_mode: "verification"
    )
    AcceptanceCriterionStep.create!(
      run_id: run.run_id, acceptance_criterion: criterion, lineage_key: "retry-the-verification"
    )
    attempt = StepAttempt.create!(
      run:, spawn_request: request, worker_id: worker.worker_id,
      lineage_key: "retry-the-verification", mode: "verification",
      outcome: "blocked", result: "[BLOCKED] Authentication role mismatch.", evidence_citations: []
    )

    expect(described_class.applicable?(attempt)).to be(true)
    expect(described_class.call(attempt)).to eq(:requeued)
    expect(run.spawn_requests.where(requested_role: "verifier", status: "open").sole.scope)
      .to eq("acceptance-verify-#{criterion.key}")
    expect(ChaperoneReview.where(run_id: run.run_id)).to be_empty
  end

  it "does not let pre-verification implementation churn consume the verifier retry budget" do
    run, criterion = create_run_with_criterion
    AcceptanceCriterionStep.create!(
      run_id: run.run_id, acceptance_criterion: criterion, lineage_key: "implement-the-thing"
    )
    Array.new(described_class::MAX_VERIFIER_ATTEMPTS) do
      worker = create_worker(run, criterion, status: "stopped")
      request = run.spawn_requests.create!(
        asked_by: "planner", requested_role: "worker", scope: "implement-the-thing.md",
        lineage_key: "implement-the-thing", status: "fulfilled", fulfilled_worker_id: worker.worker_id,
        text: "Implement it.", priority: "blocking", execution_mode: "implementation"
      )
      StepAttempt.create!(
        run:, spawn_request: request, worker_id: worker.worker_id,
        lineage_key: "implement-the-thing", mode: "implementation",
        outcome: "failed", result: "implementation churn", evidence_citations: []
      )
    end
    attempt = create_failed_attempt(run, criterion)

    expect(described_class.call(attempt)).to eq(:requeued)
    expect(run.user_questions.open_only).to be_empty
  end

  it "falls back to the chaperone path when the criterion is no longer awaiting verification" do
    run, criterion = create_run_with_criterion
    criterion.update!(status: "verified")
    create_failed_attempt(run, criterion)
    attempt = create_failed_attempt(run, criterion)

    result = described_class.call(attempt)

    expect(result).to be_a(ChaperoneReview)
    expect(run.spawn_requests.where(requested_role: "verifier", status: "open")).to be_empty
  end

  describe ".requeue_stalled_verification!" do
    it "re-arms a criterion stuck awaiting verification with nothing in flight" do
      run, criterion = create_run_with_criterion

      expect(described_class.requeue_stalled_verification!(run)).to be(true)
      expect(run.spawn_requests.where(requested_role: "verifier", status: "open").sole.scope)
        .to eq("acceptance-verify-#{criterion.key}")
    end

    it "leaves a criterion alone while a verifier request is already open" do
      run, criterion = create_run_with_criterion
      Orchestrator::AcceptanceCriteria.request_verification!(run:, criterion:)

      expect(described_class.requeue_stalled_verification!(run)).to be(false)
    end

    it "leaves a criterion alone while a verifier worker is running" do
      run, criterion = create_run_with_criterion
      create_worker(run, criterion, status: "running")

      expect(described_class.requeue_stalled_verification!(run)).to be(false)
    end

    it "escalates instead of re-arming once the attempt bound is reached" do
      run, criterion = create_run_with_criterion
      Array.new(described_class::MAX_VERIFIER_ATTEMPTS) { create_failed_attempt(run, criterion) }

      expect(described_class.requeue_stalled_verification!(run)).to be(true)
      expect(run.user_questions.open_only.where(priority: "blocking").count).to eq(1)
      expect(run.spawn_requests.where(requested_role: "verifier", status: "open")).to be_empty
    end
  end

  it "keeps worker_turn from requesting a doomed planner follow-up for a blocked verification" do
    run, criterion = create_run_with_criterion
    worker = create_worker(run, criterion, status: "running")
    request = run.spawn_requests.create!(
      asked_by: "planner", requested_role: "verifier", scope: "acceptance-verify-#{criterion.key}",
      lineage_key: "acceptance:#{criterion.key}", status: "fulfilled", fulfilled_worker_id: worker.worker_id,
      text: "Verify it.", priority: "blocking", execution_mode: "verification"
    )

    response = Orchestrator::Turn.run_worker_turn(
      run_id: run.run_id, role: "verifier", nickname: worker.nickname, scope: request.scope,
      result: "[BLOCKED] Could not reach a conclusive verdict."
    )

    expect(response[:planner_request]).to be_nil
    expect(response).not_to have_key(:chaperone_review)
    expect(run.spawn_requests.where(requested_role: "planner", status: "open")).to be_empty
    expect(run.spawn_requests.where(requested_role: "verifier", status: "open").count).to eq(1)
  end

  private

  def create_run_with_criterion
    workspace = Workspace.create!(name: "verifier-recovery-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "verifier-recovery-#{SecureRandom.hex(4)}", task: "Exercise verifier recovery",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    criterion = AcceptanceCriterion.create!(
      run_id: run.run_id, key: "outcome-works", content: "The outcome works end to end.",
      status: "ready_for_verification", evidence_ref: "Gemfile"
    )
    [ run, criterion ]
  end

  def create_worker(run, criterion, status:)
    id = SecureRandom.uuid
    run.workers.create!(
      worker_id: id, role: "verifier", nickname: "verifier-#{id.first(6)}", reason: "Verify.",
      scope: "acceptance-verify-#{criterion.key}", status:, pid: 999_999_999,
      prompt_path: "/tmp/#{id}.prompt", log_path: "/tmp/#{id}.log", last_message_path: "/tmp/#{id}.last",
      env_path: "/tmp/#{id}.env", command: "claude"
    )
  end

  def create_failed_attempt(run, criterion)
    worker = create_worker(run, criterion, status: "stopped")
    request = run.spawn_requests.create!(
      asked_by: "planner", requested_role: "verifier", scope: "acceptance-verify-#{criterion.key}",
      lineage_key: "acceptance:#{criterion.key}", status: "fulfilled", fulfilled_worker_id: worker.worker_id,
      text: "Verify it.", priority: "blocking", execution_mode: "verification"
    )
    StepAttempt.create!(
      run:, spawn_request: request, worker_id: worker.worker_id,
      lineage_key: "acceptance:#{criterion.key}", mode: "verification",
      outcome: "failed", result: "Worker exited with status 0 before completing its handoff.",
      evidence_citations: []
    )
  end
end

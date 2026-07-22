require "rails_helper"

RSpec.describe Orchestrator::ApplyChaperoneDecision do
  describe ".call" do
    it "replans a stopped diagnosis instead of asking the operator when a bounded fix may remain" do
      run = create_run
      request = run.spawn_requests.create!(
        asked_by: "planner", scope: "recording.md", text: "Record the flow.", requested_role: "infrastructure",
        priority: "blocking", lineage_key: "criterion:phone-flow", execution_mode: "recording",
        write_scope: "artifact_only", allowed_paths: []
      )
      attempt = StepAttempt.create!(
        run:, spawn_request: request, worker_id: SecureRandom.uuid, lineage_key: "criterion:phone-flow",
        mode: "recording", outcome: "blocked", result: "The exact endpoint file is front/src/config.ts."
      )
      review = ChaperoneReview.create!(
        run:, lineage_key: "criterion:phone-flow", step_attempt_ids: [ attempt.attempt_id ], subject_type: "diagnosis",
        status: "running", token_digest: SecureRandom.hex(32), expires_at: 1.hour.from_now
      )

      described_class.call(
        review:, action: "stop", summary: "The artifact-only retry cannot change the endpoint.",
        planner_tier: "strong", blocker_key: "hardcoded-endpoint",
        context_requests: [ { source: "artifact", reference: "recording.md", question: "Why did the retry fail?", max_chars: 500 } ]
      )

      expect(UserQuestion.where(run_id: run.run_id, priority: "blocking", status: "open")).to be_empty
      replan = SpawnRequest.find_by!(run_id: run.run_id, requested_role: "planner", asked_by: "chaperone")
      expect(replan.context).to include("front/src/config.ts")
      expect(replan.model_tier).to eq("strong")
      expect(replan.tags).to include("blocker:hardcoded-endpoint")
      expect(run.reload.phase).to eq("planning")
      expect(review.reload.action).to eq("stop")
    end

    it "asks only after the same blocker was already replanned at the same tier for the lineage" do
      run = create_run
      source = run.spawn_requests.create!(
        asked_by: "planner", scope: "recording.md", text: "Record the flow.", requested_role: "infrastructure",
        priority: "blocking", lineage_key: "criterion:phone-flow", execution_mode: "recording",
        write_scope: "artifact_only", allowed_paths: []
      )
      run.spawn_requests.create!(
        asked_by: "chaperone", scope: Orchestrator::Turn::PLANNER_FOLLOWUP_SCOPE, text: "Repair replan.",
        requested_role: "planner", priority: "blocking", lineage_key: "criterion:phone-flow", model_tier: "strong",
        tags: %w[planner chaperone stopped_retry replan blocker:hardcoded-endpoint]
      )
      attempt = StepAttempt.create!(
        run:, spawn_request: source, worker_id: SecureRandom.uuid, lineage_key: "criterion:phone-flow",
        mode: "recording", outcome: "blocked", result: "The first repair did not resolve the endpoint."
      )
      review = ChaperoneReview.create!(
        run:, lineage_key: "criterion:phone-flow", step_attempt_ids: [ attempt.attempt_id ], subject_type: "diagnosis",
        status: "running", token_digest: SecureRandom.hex(32), expires_at: 1.hour.from_now
      )

      described_class.call(
        review:, action: "stop", summary: "The bounded repair route is exhausted.",
        planner_tier: "strong", blocker_key: "hardcoded-endpoint",
        context_requests: [ { source: "artifact", reference: "recording.md", question: "Still blocked?", max_chars: 500 } ]
      )

      expect(UserQuestion.where(run_id: run.run_id, priority: "blocking", status: "open").count).to eq(1)
      expect(run.reload.phase).to eq("blocked_on_user")
    end

    it "still asks the operator when no plannerTier is given" do
      run = create_run
      source = run.spawn_requests.create!(
        asked_by: "planner", scope: "recording.md", text: "Record the flow.", requested_role: "infrastructure",
        priority: "blocking", lineage_key: "criterion:phone-flow", execution_mode: "recording",
        write_scope: "artifact_only", allowed_paths: []
      )
      attempt = StepAttempt.create!(
        run:, spawn_request: source, worker_id: SecureRandom.uuid, lineage_key: "criterion:phone-flow",
        mode: "recording", outcome: "blocked", result: "No safe bounded repair exists."
      )
      review = ChaperoneReview.create!(
        run:, lineage_key: "criterion:phone-flow", step_attempt_ids: [ attempt.attempt_id ], subject_type: "diagnosis",
        status: "running", token_digest: SecureRandom.hex(32), expires_at: 1.hour.from_now
      )

      described_class.call(review:, action: "stop", summary: "No safe bounded repair exists.")

      expect(UserQuestion.where(run_id: run.run_id, priority: "blocking", status: "open").count).to eq(1)
      expect(run.reload.phase).to eq("blocked_on_user")
    end

    it "allows a second replan for a genuinely different blocker in the same lineage" do
      run = create_run
      source = run.spawn_requests.create!(
        asked_by: "planner", scope: "recording.md", text: "Record the flow.", requested_role: "infrastructure",
        priority: "blocking", lineage_key: "criterion:phone-flow", execution_mode: "recording",
        write_scope: "artifact_only", allowed_paths: []
      )
      run.spawn_requests.create!(
        asked_by: "chaperone", scope: Orchestrator::Turn::PLANNER_FOLLOWUP_SCOPE, text: "Repair replan.",
        requested_role: "planner", priority: "blocking", lineage_key: "criterion:phone-flow", model_tier: "small",
        tags: %w[planner chaperone stopped_retry replan blocker:hardcoded-endpoint]
      )
      attempt = StepAttempt.create!(
        run:, spawn_request: source, worker_id: SecureRandom.uuid, lineage_key: "criterion:phone-flow",
        mode: "recording", outcome: "blocked", result: "The endpoint fix landed; recording now fails on a stale test assertion."
      )
      review = ChaperoneReview.create!(
        run:, lineage_key: "criterion:phone-flow", step_attempt_ids: [ attempt.attempt_id ], subject_type: "diagnosis",
        status: "running", token_digest: SecureRandom.hex(32), expires_at: 1.hour.from_now
      )

      described_class.call(
        review:, action: "stop", summary: "A new blocker emerged after the endpoint fix.",
        planner_tier: "small", blocker_key: "stale-test-assertion",
        context_requests: [ { source: "artifact", reference: "recording.md", question: "What broke now?", max_chars: 500 } ]
      )

      expect(UserQuestion.where(run_id: run.run_id, priority: "blocking", status: "open")).to be_empty
      replan = SpawnRequest.where(run_id: run.run_id, requested_role: "planner", asked_by: "chaperone").order(:id).last
      expect(replan.tags).to include("blocker:stale-test-assertion")
      expect(run.reload.phase).to eq("planning")
    end

    it "allows escalating the same blocker to a stronger tier after the small-tier replan was scoped too narrowly" do
      run = create_run
      source = run.spawn_requests.create!(
        asked_by: "planner", scope: "recording.md", text: "Record the flow.", requested_role: "infrastructure",
        priority: "blocking", lineage_key: "criterion:phone-flow", execution_mode: "recording",
        write_scope: "artifact_only", allowed_paths: []
      )
      run.spawn_requests.create!(
        asked_by: "chaperone", scope: Orchestrator::Turn::PLANNER_FOLLOWUP_SCOPE, text: "Repair replan.",
        requested_role: "planner", priority: "blocking", lineage_key: "criterion:phone-flow", model_tier: "small",
        tags: %w[planner chaperone stopped_retry replan blocker:hardcoded-endpoint]
      )
      attempt = StepAttempt.create!(
        run:, spawn_request: source, worker_id: SecureRandom.uuid, lineage_key: "criterion:phone-flow",
        mode: "recording", outcome: "blocked", result: "The small-tier replan excluded the file that needed the fix."
      )
      review = ChaperoneReview.create!(
        run:, lineage_key: "criterion:phone-flow", step_attempt_ids: [ attempt.attempt_id ], subject_type: "diagnosis",
        status: "running", token_digest: SecureRandom.hex(32), expires_at: 1.hour.from_now
      )

      described_class.call(
        review:, action: "stop", summary: "The small-tier envelope excluded the file that needed the fix.",
        planner_tier: "strong", blocker_key: "hardcoded-endpoint",
        context_requests: [ { source: "artifact", reference: "recording.md", question: "Still blocked?", max_chars: 500 } ]
      )

      expect(UserQuestion.where(run_id: run.run_id, priority: "blocking", status: "open")).to be_empty
      replan = SpawnRequest.find_by!(run_id: run.run_id, requested_role: "planner", asked_by: "chaperone", model_tier: "strong")
      expect(replan.tags).to include("blocker:hardcoded-endpoint")
      expect(run.reload.phase).to eq("planning")
    end
  end

  describe ".handle_review_failure" do
    it "fails the awaiting planner decision and asks the operator, so it stops counting as active work" do
      run = create_run
      request = run.spawn_requests.create!(
        asked_by: "planner", scope: "workflow-plan.md", text: "Plan the next step.",
        requested_role: "planner", priority: "blocking"
      )
      decision = run.planner_decisions.create!(spawn_request: request, status: "awaiting_chaperone")
      review = ChaperoneReview.create!(
        run:, lineage_key: "planner:#{decision.decision_id}", step_attempt_ids: [], subject_type: "planner",
        subject_id: decision.decision_id, status: "failed", summary: "Execution error",
        token_digest: SecureRandom.hex(32), expires_at: 1.hour.from_now, completed_at: Time.current
      )

      described_class.handle_review_failure(review: review)

      expect(decision.reload.status).to eq("failed")
      expect(decision.error).to include("Execution error")
      expect(PlannerDecision::ACTIVE_STATUSES).not_to include(decision.status)
      question = UserQuestion.find_by!(run_id: run.run_id, priority: "blocking", status: "open")
      expect(question.scope).to eq("workflow-plan.md")
      expect(question.tags).to include("execution_failed")
      expect(run.reload.phase).to eq("blocked_on_user")
    end

    it "fails the reviewed step attempts when the review's subject is a diagnosis lineage" do
      run = create_run
      request = run.spawn_requests.create!(
        asked_by: "planner", scope: "diagnosis.md", text: "Diagnose it.",
        requested_role: "worker", priority: "blocking", lineage_key: "diagnose-it"
      )
      attempt = StepAttempt.create!(
        run:, spawn_request: request, worker_id: SecureRandom.uuid, lineage_key: "diagnose-it",
        mode: "diagnosis", outcome: "blocked", result: "Could not reproduce.", chaperone_status: "queued"
      )
      review = ChaperoneReview.create!(
        run:, lineage_key: "diagnose-it", step_attempt_ids: [ attempt.attempt_id ], subject_type: "diagnosis",
        status: "failed", summary: "Execution error", token_digest: SecureRandom.hex(32),
        expires_at: 1.hour.from_now, completed_at: Time.current
      )

      described_class.handle_review_failure(review: review)

      expect(attempt.reload.chaperone_status).to eq("failed")
      question = UserQuestion.find_by!(run_id: run.run_id, priority: "blocking", status: "open")
      expect(question.scope).to eq("diagnosis.md")
      expect(run.reload.phase).to eq("blocked_on_user")
    end

    it "is idempotent -- a second call for the same already-reconciled review does not create a duplicate question" do
      run = create_run
      request = run.spawn_requests.create!(
        asked_by: "planner", scope: "workflow-plan.md", text: "Plan the next step.",
        requested_role: "planner", priority: "blocking"
      )
      decision = run.planner_decisions.create!(spawn_request: request, status: "awaiting_chaperone")
      review = ChaperoneReview.create!(
        run:, lineage_key: "planner:#{decision.decision_id}", step_attempt_ids: [], subject_type: "planner",
        subject_id: decision.decision_id, status: "failed", summary: "Execution error",
        token_digest: SecureRandom.hex(32), expires_at: 1.hour.from_now, completed_at: Time.current
      )

      2.times { described_class.handle_review_failure(review: review) }

      expect(UserQuestion.where(run_id: run.run_id, priority: "blocking").count).to eq(1)
    end

    it "does nothing for a review that has not failed" do
      run = create_run
      review = ChaperoneReview.create!(
        run:, lineage_key: "diagnosis-lineage", step_attempt_ids: [], subject_type: "diagnosis",
        status: "queued", token_digest: SecureRandom.hex(32), expires_at: 1.hour.from_now
      )

      described_class.handle_review_failure(review: review)

      expect(UserQuestion.where(run_id: run.run_id).count).to eq(0)
    end
  end

  def create_run
    root = Dir.mktmpdir("apply-chaperone-decision")
    workspace = Workspace.create!(name: "apply-chaperone-#{SecureRandom.hex(4)}", root_path: root)
    workspace.runs.create!(
      run_id: "apply-chaperone-#{SecureRandom.hex(4)}", task: "Exercise chaperone review failure handling",
      target_root: root, launcher_variant: "claude", status: "running"
    )
  end
end

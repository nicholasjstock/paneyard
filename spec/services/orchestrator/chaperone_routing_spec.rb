require "rails_helper"

RSpec.describe "chaperone routing" do
  it "queues a strong chaperone after the second failed diagnosis in one lineage" do
    run = build_run
    first = report_failure(run, 1)
    assert first[:planner_request]
    assert_nil first[:chaperone_review]

    assert_difference -> { SpawnRequest.where(requested_role: "chaperone").count }, 1 do
      second = report_failure(run, 2)
      assert_nil second[:planner_request]
      assert second[:chaperone_review]
    end

    review = run.chaperone_reviews.last
    assert_equal "queued", review.status
    assert_equal "admin-session", review.lineage_key
    assert_equal 2, review.step_attempt_ids.length
  end

  it "queues a strong chaperone after the second failed recording attempt in one lineage, not only diagnosis" do
    run = build_run
    first = report_failure(run, 1, mode: "recording", tag: "[BLOCKED]")
    assert first[:planner_request]
    assert_nil first[:chaperone_review]

    assert_difference -> { SpawnRequest.where(requested_role: "chaperone").count }, 1 do
      second = report_failure(run, 2, mode: "recording", tag: "[BLOCKED]")
      assert_nil second[:planner_request]
      assert second[:chaperone_review]
    end

    review = run.chaperone_reviews.last
    assert_equal "admin-session", review.lineage_key
    assert_equal 2, review.step_attempt_ids.length
    assert_equal %w[recording recording], StepAttempt.where(attempt_id: review.step_attempt_ids).order(:created_at).pluck(:mode)
  end

  it "records a done step attempt outside diagnosis without requiring evidence citations" do
    run = build_run

    assert_difference -> { StepAttempt.count }, 1 do
      report_success(run, 1, mode: "recording")
    end

    attempt = StepAttempt.last
    assert_equal "done", attempt.outcome
    assert_equal "recording", attempt.mode
  end

  it "queues a strong chaperone after two failures under different lineage_keys that address the same acceptance criterion" do
    run = build_run
    criterion = run.acceptance_criteria.create!(key: "demo-perf-baseline", content: "Baseline measured", status: "in_progress")

    first = report_failure_for_criterion(run, 1, criterion:, lineage_key: "measure-demo-performance", mode: "recording")
    assert_nil first[:chaperone_review]

    assert_difference -> { SpawnRequest.where(requested_role: "chaperone").count }, 1 do
      second = report_failure_for_criterion(run, 2, criterion:, lineage_key: "diagnosis:record-demo-port-config", mode: "diagnosis")
      assert second[:chaperone_review]
    end

    review = run.chaperone_reviews.last
    assert_equal "criterion:demo-perf-baseline", review.lineage_key
    assert_equal 2, review.step_attempt_ids.length
  end

  it "does not trigger a chaperone across two failures addressing different acceptance criteria" do
    run = build_run
    criterion_a = run.acceptance_criteria.create!(key: "criterion-a", content: "A resolved", status: "in_progress")
    criterion_b = run.acceptance_criteria.create!(key: "criterion-b", content: "B resolved", status: "in_progress")

    report_failure_for_criterion(run, 1, criterion: criterion_a, lineage_key: "lineage-a", mode: "recording")
    second = report_failure_for_criterion(run, 2, criterion: criterion_b, lineage_key: "lineage-b", mode: "recording")

    assert_nil second[:chaperone_review]
    assert_equal 0, run.chaperone_reviews.count
  end

  it "promotion preserves the diagnosis lineage and requests the strong worker tier" do
    run = build_run
    report_failure(run, 1)
    report_failure(run, 2)
    review = run.chaperone_reviews.last

    assert_difference -> { run.spawn_requests.count }, 1 do
      Orchestrator::ApplyChaperoneDecision.call(review:, action: "promote", summary: "The attempts repeat the same unsupported conclusion.")
    end

    request = run.spawn_requests.order(:created_at).last
    assert_equal "admin-session", request.lineage_key
    assert_equal "strong", request.model_tier
    assert_equal "chaperone", request.asked_by
    assert_equal "completed", review.reload.status
  end

  it "continue_small with a revised instruction replaces the retry text but preserves the original execution mode" do
    run = build_run
    report_failure(run, 1, mode: "recording")
    report_failure(run, 2, mode: "recording")
    review = run.chaperone_reviews.last

    Orchestrator::ApplyChaperoneDecision.call(
      review:, action: "continue_small", summary: "Both attempts hit the same wrong backend port.",
      revised_instruction: "Start the backend on port 3001 before recording, then retry."
    )

    request = run.spawn_requests.order(:created_at).last
    assert_equal "Start the backend on port 3001 before recording, then retry.", request.text
    assert_equal "recording", request.execution_mode
    assert_equal "small", request.model_tier
  end

  it "continue_small without a revised instruction repeats the original instruction unchanged" do
    run = build_run
    report_failure(run, 1, mode: "recording")
    report_failure(run, 2, mode: "recording")
    review = run.chaperone_reviews.last
    original_text = review.step_attempt_ids.map { |id| StepAttempt.find_by(attempt_id: id).spawn_request.text }.last

    Orchestrator::ApplyChaperoneDecision.call(review:, action: "continue_small", summary: "Retry as-is.")

    request = run.spawn_requests.order(:created_at).last
    assert_equal original_text, request.text
  end

  it "only a chaperone decision can promote a planner request" do
    run = build_run
    request = run.spawn_requests.create!(
      asked_by: "worker", scope: "workflow-plan.md", text: "Choose the next step.",
      requested_role: "planner", priority: "blocking", status: "fulfilled", fulfilled_by: "planner_decision_job"
    )
    decision = PlannerDecision.create!(run:, spawn_request: request, status: "awaiting_chaperone")
    review, = ChaperoneReview.issue!(
      run:, lineage_key: "planner:#{decision.decision_id}", step_attempt_ids: [],
      subject_type: "planner", subject_id: decision.decision_id, summary: "Small planner requested promotion."
    )

    Orchestrator::ApplyChaperoneDecision.call(review:, action: "promote", summary: "The bounded decision warrants stronger reasoning.")

    assert_equal "strong", request.reload.model_tier
    assert_equal "open", request.status
    assert_equal "failed", decision.reload.status
    assert_equal "completed", review.reload.status
  end

  it "applies evidence-based revised context when retrying a planner" do
    run = build_run
    request = run.spawn_requests.create!(
      asked_by: "worker", scope: "workflow-plan.md", text: "Choose the next step.",
      requested_role: "planner", priority: "blocking", status: "fulfilled", fulfilled_by: "planner_decision_job"
    )
    decision = PlannerDecision.create!(run:, spawn_request: request, status: "awaiting_chaperone")
    review, = ChaperoneReview.issue!(
      run:, lineage_key: "planner:#{decision.decision_id}", step_attempt_ids: [], subject_type: "planner",
      subject_id: decision.decision_id, summary: "The backend port was already occupied."
    )

    Orchestrator::ApplyChaperoneDecision.call(
      review:, action: "continue_small", summary: "Use the alternate local port from the recorded evidence.",
      revised_instruction: "Plan the next step using port 3001; port 3000 is occupied by Rails."
    )

    request.reload
    assert_equal "small", request.model_tier
    assert_equal "open", request.status
    assert_equal "Plan the next step using port 3001; port 3000 is occupied by Rails.", request.text
    assert_includes request.context, "Use the alternate local port from the recorded evidence."
  end

  it "stopping a planner asks an actionable question and keeps the conclusion as context" do
    run = build_run
    request = run.spawn_requests.create!(
      asked_by: "worker", scope: "workflow-plan.md", text: "Choose the next step.",
      requested_role: "planner", priority: "blocking", status: "fulfilled", fulfilled_by: "planner_decision_job"
    )
    decision = PlannerDecision.create!(run:, spawn_request: request, status: "awaiting_chaperone")
    review, = ChaperoneReview.issue!(
      run:, lineage_key: "planner:#{decision.decision_id}", step_attempt_ids: [],
      subject_type: "planner", subject_id: decision.decision_id,
      summary: "Small planner requested promotion."
    )
    review.update!(trigger_reason: "protected paths proposed")
    conclusion = "Verification targeted the wrong service, so protected backend edits are not justified."

    assert_difference -> { run.user_questions.count }, 1 do
      Orchestrator::ApplyChaperoneDecision.call(review:, action: "stop", summary: conclusion)
    end

    question = run.user_questions.order(:created_at).last
    assert question.text.end_with?("?")
    assert_not_includes question.text, conclusion
    assert_includes question.context, conclusion
    assert_includes question.context, "protected paths proposed"
    assert_equal "blocking", question.priority
  end

  it "stopping repeated diagnosis separates the decision from its explanation" do
    run = build_run
    report_failure(run, 1)
    report_failure(run, 2)
    review = run.chaperone_reviews.last
    conclusion = "Both attempts repeated the same unsupported diagnosis."

    Orchestrator::ApplyChaperoneDecision.call(review:, action: "stop", summary: conclusion)

    question = run.user_questions.order(:created_at).last
    assert question.text.end_with?("?")
    assert_not_includes question.text, conclusion
    assert_includes question.context, conclusion
  end

  private

  def report_failure(run, number, mode: "diagnosis", tag: "[BLOCKED]")
    scope = "diagnosis-#{number}.md"
    request = run.spawn_requests.create!(
      asked_by: "planner", scope:, text: "Execution mode: #{mode}. Inspect admin auth.",
      requested_role: "worker", priority: "blocking", status: "fulfilled",
      fulfilled_worker_id: SecureRandom.uuid, lineage_key: "admin-session", execution_mode: mode
    )
    worker = create_worker(run, request, number)
    request.update!(fulfilled_worker_id: worker.worker_id)
    Orchestrator::ArtifactStore.write(run.target_root, run.run_id, scope, "login screen remained visible")
    args = { run_id: run.run_id, role: "worker", nickname: worker.nickname, scope:,
              result: "#{tag} Admin login remained.", previous_state: Orchestrator::TickState.latest(run.run_id) }
    if mode == "diagnosis"
      args.merge!(evidence_outcome: "blocked", evidence_citations: [ "login screen remained visible" ])
    end
    Orchestrator::Turn.run_worker_turn(**args)
  end

  def report_success(run, number, mode:)
    scope = "success-#{number}.md"
    request = run.spawn_requests.create!(
      asked_by: "planner", scope:, text: "Execution mode: #{mode}. Record the demo.",
      requested_role: "worker", priority: "blocking", status: "fulfilled",
      fulfilled_worker_id: SecureRandom.uuid, lineage_key: "recording-session"
    )
    worker = create_worker(run, request, number)
    request.update!(fulfilled_worker_id: worker.worker_id)
    Orchestrator::Turn.run_worker_turn(
      run_id: run.run_id, role: "worker", nickname: worker.nickname, scope:,
      result: "[DONE] Recording captured.", previous_state: Orchestrator::TickState.latest(run.run_id)
    )
  end

  def report_failure_for_criterion(run, number, criterion:, lineage_key:, mode:)
    scope = "attempt-#{number}.md"
    request = run.spawn_requests.create!(
      asked_by: "planner", scope:, text: "Execution mode: #{mode}. Work toward #{criterion.key}.",
      requested_role: "worker", priority: "blocking", status: "fulfilled",
      fulfilled_worker_id: SecureRandom.uuid, lineage_key:
    )
    worker = create_worker(run, request, number)
    request.update!(fulfilled_worker_id: worker.worker_id)
    criterion.fulfillment_steps.create!(run_id: run.run_id, lineage_key:)

    args = { run_id: run.run_id, role: "worker", nickname: worker.nickname, scope:,
              result: "[BLOCKED] Could not complete.", previous_state: Orchestrator::TickState.latest(run.run_id) }
    if mode == "diagnosis"
      Orchestrator::ArtifactStore.write(run.target_root, run.run_id, scope, "evidence text")
      args.merge!(evidence_outcome: "blocked", evidence_citations: [ "evidence text" ])
    end
    Orchestrator::Turn.run_worker_turn(**args)
  end

  def create_worker(run, request, number)
    run.workers.create!(
      worker_id: SecureRandom.uuid, role: "worker", nickname: "diagnosis-#{number}", reason: request.text,
      scope: request.scope, status: "running", pid: 10_000 + number, command: "claude", args: [],
      prompt_path: Rails.root.join("tmp/d#{number}.prompt").to_s, log_path: Rails.root.join("tmp/d#{number}.log").to_s,
      last_message_path: Rails.root.join("tmp/d#{number}.last").to_s, env_path: Rails.root.join("tmp/d#{number}.env").to_s,
      model: "haiku"
    )
  end

  def build_run
    root = Dir.mktmpdir("chaperone-routing")
    workspace = Workspace.create!(name: "chaperone-#{SecureRandom.hex(4)}", root_path: root)
    workspace.runs.create!(run_id: "chaperone-#{SecureRandom.hex(4)}", task: "Fix admin flow", target_root: root, launcher_variant: "claude", status: "running")
  end
end

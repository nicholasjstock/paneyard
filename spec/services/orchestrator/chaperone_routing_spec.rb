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

  def report_failure(run, number)
    scope = "diagnosis-#{number}.md"
    request = run.spawn_requests.create!(
      asked_by: "planner", scope:, text: "Execution mode: diagnosis. Inspect admin auth.",
      requested_role: "worker", priority: "blocking", status: "fulfilled",
      fulfilled_worker_id: SecureRandom.uuid, lineage_key: "admin-session"
    )
    worker = create_worker(run, request, number)
    request.update!(fulfilled_worker_id: worker.worker_id)
    Orchestrator::ArtifactStore.write(run.target_root, run.run_id, scope, "login screen remained visible")
    Orchestrator::Turn.run_worker_turn(
      run_id: run.run_id, role: "worker", nickname: worker.nickname, scope:,
      result: "[BLOCKED] Admin login remained.", evidence_outcome: "blocked",
      evidence_citations: [ "login screen remained visible" ], previous_state: Orchestrator::TickState.latest(run.run_id)
    )
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

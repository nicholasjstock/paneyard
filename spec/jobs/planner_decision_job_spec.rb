require "rails_helper"

RSpec.describe PlannerDecisionJob do
  it "applies aggregate usage/model from the runner once the decision has been submitted via the tool" do
    run, _request, record = build_decision

    with_stubbed_runner(->(decision:, **) {
      Orchestrator::PlannerDecisionSubmission.call(
        decision:,
        params: {
          outcome: "decision", summary: "Run the verification.",
          next_step: {
            owner: "worker", artifact: "verify.md", success_check: "Confirm behavior.",
            mode: "verification", write_scope: "artifact_only", allowed_paths: [], evidence_refs: [],
            addresses_criteria: [ "existing-outcome" ]
          },
          following_steps: [], context_request: nil, acceptance_criteria: [], acceptance_updates: []
        }
      )
      { usage: { input_tokens: 100, output_tokens: 20 }, model: "sonnet" }
    }) do
      PlannerDecisionJob.perform_now(record.id)
    end

    assert_equal "completed", record.reload.status
    assert_equal 100, record.input_tokens
    assert_equal "sonnet", record.model
    assert_equal 1, record.model_calls
    assert_equal "verify.md", run.spawn_requests.open_only.find_by!(requested_role: "worker").scope
  end

  it "fails the run when the process exits cleanly without ever submitting a decision" do
    run, _request, record = build_decision

    with_stubbed_runner(->(**) { { usage: {}, model: "haiku" } }) do
      expect { PlannerDecisionJob.perform_now(record.id) }.to raise_error(Orchestrator::PlannerDecisionRunner::Error)
    end

    assert_equal "failed", record.reload.status
    assert_equal "failed", run.reload.status
  end

  it "fails the run instead of retrying an invalid planner call forever" do
    run, request, record = build_decision
    error = Orchestrator::PlannerDecisionRunner::Error.new("invalid structured response")

    with_stubbed_runner(->(**) { raise error }) do
      assert_raises(Orchestrator::PlannerDecisionRunner::Error) { PlannerDecisionJob.perform_now(record.id) }
    end

    assert_equal "failed", record.reload.status
    assert_equal "fulfilled", request.reload.status
    assert_equal "failed", run.reload.status
    assert_equal "failed", run.phase
  end

  it "does not fail an already-completed decision even if the runner raises afterward" do
    run, _request, record = build_decision

    with_stubbed_runner(->(decision:, **) {
      Orchestrator::PlannerDecisionSubmission.call(
        decision:,
        params: {
          outcome: "decision", summary: "Done.",
          next_step: nil, following_steps: [], context_request: nil, acceptance_criteria: [], acceptance_updates: []
        }
      )
      raise Orchestrator::PlannerDecisionRunner::Error, "late nonzero exit after the tool already succeeded"
    }) do
      expect { PlannerDecisionJob.perform_now(record.id) }.not_to raise_error
    end

    assert_equal "completed", record.reload.status
    assert_equal "running", run.reload.status
  end

  it "reopens the request and blocks the run for capacity on a rate-limit failure" do
    run, request, record = build_decision
    error = Orchestrator::PlannerDecisionRunner::Error.new("hit your session limit · resets 5pm (Europe/Paris)")

    with_stubbed_runner(->(**) { raise error }) do
      assert_raises(Orchestrator::PlannerDecisionRunner::Error) { PlannerDecisionJob.perform_now(record.id) }
    end

    assert_equal "failed", record.reload.status
    assert_equal "open", request.reload.status
    assert_equal "running", run.reload.status
    assert_operator run.capacity_available_at, :>, Time.current
    assert_equal "waiting_on_capacity", run.phase
  end

  private

  def with_stubbed_runner(replacement)
    singleton = Orchestrator::PlannerDecisionRunner.singleton_class
    original = singleton.instance_method(:call)
    singleton.define_method(:call, replacement)
    yield
  ensure
    singleton&.define_method(:call, original) if original
  end

  def build_decision(with_acceptance: true)
    workspace = Workspace.create!(name: "planner-job-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s)
    run = workspace.runs.create!(
      run_id: "planner-job-#{SecureRandom.hex(4)}", task: "Complete the workflow",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    request = run.spawn_requests.create!(
      asked_by: "worker", scope: "workflow-plan.md", text: "Choose the next step.",
      requested_role: "planner", priority: "blocking", status: "fulfilled", fulfilled_by: "planner_decision_job"
    )
    record = PlannerDecision.create!(run:, spawn_request: request, status: "queued")
    if with_acceptance
      AcceptanceCriterion.create!(
        run_id: run.run_id, key: "existing-outcome", status: "verified",
        content: "Existing test outcome", evidence_ref: "Gemfile"
      )
    end
    [ run, request, record ]
  end
end

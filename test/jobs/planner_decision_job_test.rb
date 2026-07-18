require "test_helper"

class PlannerDecisionJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  test "persists and dispatches one bounded model decision" do
    run, request, record = build_decision
    result = {
      summary: "Run the verification.",
      next_step: {
        owner: "worker", artifact: "verify.md", success_check: "Confirm behavior.",
        mode: "verification", write_scope: "artifact_only", allowed_paths: [], evidence_refs: []
      },
      following_steps: [], usage: { input_tokens: 100, output_tokens: 20 }, model: "sonnet"
    }

    with_stubbed_runner(->(**) { result }) do
      PlannerDecisionJob.perform_now(record.id)
    end

    assert_equal "completed", record.reload.status
    assert_equal 100, record.input_tokens
    assert_equal "sonnet", record.model
    assert_equal "verify.md", run.spawn_requests.open_only.find_by!(requested_role: "worker").scope
    assert_equal "planning", Orchestrator::TickState.latest(run.run_id)[:phase]
  end

  test "fails the run instead of retrying an invalid planner call forever" do
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

  test "routes a policy-invalid small plan to the chaperone without self-promoting" do
    run, _request, record = build_decision
    tiers = []
    runner = lambda do |model_tier:, **|
      tiers << model_tier
      {
        outcome: "decision", summary: "Change the application.",
        next_step: {
          owner: "worker", artifact: "fix.md", success_check: "Implement the performance fix.",
          mode: "implementation", write_scope: "scoped_changes", allowed_paths: [ "front/" ], evidence_refs: [ "guess" ]
        },
        following_steps: [], context_request: nil, usage: {},
        model: model_tier == :small ? "haiku" : "sonnet", model_tier: model_tier.to_s
      }
    end

    assert_enqueued_with(job: ChaperoneReviewJob) do
      with_stubbed_runner(runner) { PlannerDecisionJob.perform_now(record.id) }
    end

    assert_equal [ :small ], tiers
    assert_equal 1, record.reload.model_calls
    assert_equal "awaiting_chaperone", record.status
    assert_equal "planner", run.chaperone_reviews.last.subject_type
  end

  test "does not complete a run after a blocked worker handoff" do
    run, request, record = build_decision
    request.update!(tags: %w[planner worker-turn-followup evidence-blocked])
    result = {
      outcome: "decision", summary: "No executable steps remain.", next_step: nil,
      following_steps: [], context_request: nil, usage: {}, model: "haiku", model_tier: "small"
    }

    assert_enqueued_with(job: ChaperoneReviewJob) do
      with_stubbed_runner(->(**) { result }) { PlannerDecisionJob.perform_now(record.id) }
    end

    assert_equal "awaiting_chaperone", record.reload.status
    assert_equal "running", run.reload.status
    assert_equal "planner", run.chaperone_reviews.last.subject_type
  end

  test "reruns with narrowly requested context before committing a decision" do
    run, _request, record = build_decision
    Orchestrator::ArtifactStore.write(run.target_root, run.run_id, "diagnosis.md", "Confirmed boundary: admin session was missing.")
    calls = []
    runner = lambda do |additional_context:, **|
      calls << additional_context
      if additional_context.empty?
        {
          outcome: "needs_context", summary: "Need the diagnosis.", next_step: nil, following_steps: [],
          context_request: {
            source: "artifact", reference: "diagnosis.md", question: "What boundary was confirmed?",
            offset: nil, max_chars: 2_000
          },
          usage: { input_tokens: 50, output_tokens: 10 }, model: "sonnet"
        }
      else
        {
          outcome: "decision", summary: "Implement the confirmed fix.",
          next_step: {
            owner: "worker", artifact: "fix.md", success_check: "Apply the confirmed session fix.",
            mode: "implementation", write_scope: "scoped_changes",
            allowed_paths: [ "front/scripts/record-demo.ts" ], evidence_refs: [ "diagnosis.md" ]
          },
          following_steps: [], context_request: nil,
          usage: { input_tokens: 70, output_tokens: 20 }, model: "sonnet"
        }
      end
    end

    with_stubbed_runner(runner) { PlannerDecisionJob.perform_now(record.id) }

    assert_equal 2, calls.length
    assert_includes calls.last.first[:content], "admin session was missing"
    assert_equal 120, record.reload.input_tokens
    assert_equal 30, record.output_tokens
    assert_equal 2, record.model_calls
    assert_equal 46, record.context_bytes
    assert_equal 2_000, record.context_requests.first.fetch("max_chars")
    assert_equal "fix.md", run.spawn_requests.open_only.find_by!(requested_role: "worker").scope
  end

  test "turns repeated unavailable context into a bounded diagnosis" do
    run, _request, record = build_decision
    calls = 0
    tiers = []
    runner = lambda do |model_tier:, **|
      calls += 1
      tiers << model_tier
      {
        outcome: "needs_context", summary: "Still need more.", next_step: nil, following_steps: [],
        context_request: {
          source: "artifact", reference: "missing-#{calls}.md", question: "What happened on attempt #{calls}?", offset: nil, max_chars: 1_000
        },
        usage: {}, model: model_tier == :small ? "haiku" : "sonnet", model_tier: model_tier.to_s
      }
    end

    with_stubbed_runner(runner) { PlannerDecisionJob.perform_now(record.id) }

    assert_equal 1, calls
    assert_equal [ :small ], tiers
    assert_equal "completed", record.reload.status
    assert_equal 1, record.model_calls
    assert_equal 1, record.context_requests.length
    diagnosis = run.spawn_requests.open_only.find_by!(requested_role: "worker")
    assert_equal "initial-diagnosis.md", diagnosis.scope
    assert_equal "planner-job", diagnosis.tags.last
    assert_equal "planner", diagnosis.asked_by
  end

  test "small planner requests chaperone review instead of promoting itself" do
    run, _request, record = build_decision
    tiers = []
    runner = lambda do |model_tier:, **|
      tiers << model_tier
      if model_tier == :small
        {
          outcome: "needs_stronger_model", summary: "This decision needs stronger reasoning.",
          next_step: nil, following_steps: [], context_request: nil,
          usage: { input_tokens: 20, output_tokens: 5 }, model: "haiku", model_tier: "small"
        }
      else
        {
          outcome: "decision", summary: "Use the verified path.", next_step: nil, following_steps: [],
          context_request: nil, usage: { input_tokens: 30, output_tokens: 8 },
          model: "sonnet", model_tier: "strong"
        }
      end
    end

    assert_enqueued_with(job: ChaperoneReviewJob) do
      with_stubbed_runner(runner) { PlannerDecisionJob.perform_now(record.id) }
    end

    assert_equal [ :small ], tiers
    assert_equal 1, record.reload.model_calls
    assert_equal [ "small" ], record.model_attempts.map { |attempt| attempt.fetch("tier") }
    assert_equal "awaiting_chaperone", record.status
    assert_equal "planner", run.chaperone_reviews.last.subject_type
  end

  test "returns to the small model after a promoted planner receives fresh context" do
    run, request, record = build_decision
    request.update!(model_tier: "strong")
    Orchestrator::ArtifactStore.write(run.target_root, run.run_id, "diagnosis.md", "Exact target: front/scripts/record-demo.ts")
    tiers = []
    final_context = nil
    runner = lambda do |model_tier:, additional_context:, **|
      tiers << model_tier
      if tiers == [ :strong ]
        {
          outcome: "needs_context", summary: "Need the exact path.", next_step: nil, following_steps: [],
          context_request: { source: "artifact", reference: "diagnosis.md", question: "What is the target?", offset: 0, max_chars: 1_000 },
          usage: {}, model: "sonnet", model_tier: "strong"
        }
      else
        final_context = additional_context.last[:content]
        {
          outcome: "decision", summary: "The small model can use the resolved fact.", next_step: nil,
          following_steps: [], context_request: nil, usage: {}, model: "haiku", model_tier: "small"
        }
      end
    end

    with_stubbed_runner(runner) { PlannerDecisionJob.perform_now(record.id) }

    assert_equal %i[strong small], tiers
    assert_equal %w[strong small], record.reload.model_attempts.map { |attempt| attempt.fetch("tier") }
    assert_includes final_context, "front/scripts/record-demo.ts"
  end

  test "strips excess path authority from a strong verification plan instead of restarting diagnosis" do
    run, request, record = build_decision
    request.update!(model_tier: "strong")
    runner = lambda do |**|
      {
        outcome: "decision", summary: "Verify the completed optimization.",
        next_step: {
          owner: "worker", artifact: "verification-results.md", success_check: "Measure runtime below 200 seconds.",
          mode: "verification", write_scope: "artifact_only",
          allowed_paths: [ "front/scripts/record-demo.ts" ], evidence_refs: [ "performance-optimization.md" ]
        },
        following_steps: [], context_request: nil, usage: {}, model: "sonnet", model_tier: "strong"
      }
    end

    with_stubbed_runner(runner) { PlannerDecisionJob.perform_now(record.id) }

    assert_equal "completed", record.reload.status
    assert_empty record.decision.dig("next_step", "allowed_paths")
    assert_equal "verification-results.md", run.spawn_requests.open_only.find_by!(requested_role: "worker").scope
    refute_equal "initial-diagnosis.md", run.spawn_requests.open_only.first.scope
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

  def build_decision
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
    [ run, request, record ]
  end
end

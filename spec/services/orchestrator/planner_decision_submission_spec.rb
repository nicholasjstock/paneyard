require "rails_helper"

RSpec.describe Orchestrator::PlannerDecisionSubmission do
  describe "outcome: decision" do
    it "persists a decision and dispatches the follow-up worker request" do
      run, _request, decision = build_decision
      params = decision_params(
        summary: "Run the verification.",
        next_step: step("verify.md", mode: "verification")
      )

      result = described_class.call(decision:, params:)

      expect(result).to eq({ accepted: true })
      assert_equal "completed", decision.reload.status
      assert_equal "verify.md", run.spawn_requests.open_only.find_by!(requested_role: "worker").scope
      assert_equal "planning", Orchestrator::TickState.latest(run.run_id)[:phase]
    end

    it "returns the rejection as data instead of escalating on the first policy-invalid plan" do
      run, _request, decision = build_decision
      params = decision_params(
        summary: "Diagnose it.",
        next_step: step("diagnosis.md", mode: "diagnosis", success_check: "Fix the bug directly.")
      )

      result = described_class.call(decision:, params:)

      expect(result[:accepted]).to be(false)
      expect(result[:error]).to eq("diagnosis step cannot also request implementation")
      assert_equal "running", decision.reload.status
      assert_empty run.chaperone_reviews
      attempt = decision.attempts.sole
      assert_equal "rejected", attempt.disposition
    end

    it "rejects an artifact path and lets the planner repair it before any worker is dispatched" do
      run, _request, decision = build_decision
      invalid = decision_params(
        summary: "Measure the baseline.",
        next_step: step("artifacts/phone-demo-baseline.md", mode: "diagnosis")
      )

      rejected = described_class.call(decision:, params: invalid)

      expect(rejected).to eq(
        accepted: false,
        error: 'artifact must be a filename only, without a path prefix: "artifacts/phone-demo-baseline.md"'
      )
      assert_equal "running", decision.reload.status
      assert_empty run.spawn_requests.open_only.where(requested_role: "worker")

      accepted = described_class.call(
        decision:,
        params: decision_params(summary: "Measure the baseline.", next_step: step("phone-demo-baseline.md", mode: "diagnosis"))
      )

      expect(accepted).to eq({ accepted: true })
      assert_equal "phone-demo-baseline.md", run.spawn_requests.open_only.find_by!(requested_role: "worker").scope
    end

    it "escalates to chaperone after repeated rejections on the small tier" do
      run, _request, decision = build_decision
      params = decision_params(
        summary: "Diagnose it.",
        next_step: step("diagnosis.md", mode: "diagnosis", success_check: "Fix the bug directly.")
      )

      results = Array.new(described_class::MAX_REJECTED_DECISION_ATTEMPTS) { described_class.call(decision:, params: params.deep_dup) }

      expect(results[0..-2]).to all(include(accepted: false))
      expect(results.last).to eq({ accepted: true, escalated: true })
      assert_equal "awaiting_chaperone", decision.reload.status
      assert_equal "planner", run.chaperone_reviews.last.subject_type
      assert_equal described_class::MAX_REJECTED_DECISION_ATTEMPTS, decision.attempts.where(disposition: "rejected").count
    end

    it "falls back to safe diagnosis instead of escalating on the strong tier" do
      run, request, decision = build_decision
      request.update!(model_tier: "strong")
      params = decision_params(
        summary: "Diagnose it.",
        next_step: step("diagnosis.md", mode: "diagnosis", success_check: "Fix the bug directly.")
      )

      results = Array.new(described_class::MAX_REJECTED_DECISION_ATTEMPTS) { described_class.call(decision:, params: params.deep_dup) }

      expect(results.last).to eq({ accepted: true, escalated: true })
      assert_equal "completed", decision.reload.status
      assert_empty run.chaperone_reviews
      assert_equal "initial-diagnosis.md", run.spawn_requests.open_only.find_by!(requested_role: "worker").scope
    end

    it "ignores acceptanceCriteria when the contract is already established" do
      run, _request, decision = build_decision(with_acceptance: true)
      params = decision_params(
        summary: "Continue with existing acceptance.",
        next_step: step("diagnosis.md", mode: "diagnosis"),
        acceptance_criteria: [ { key: "replacement", content: "Replace the contract" } ]
      )

      result = described_class.call(decision:, params:)

      expect(result).to eq({ accepted: true })
      expect(decision.reload.decision.fetch("acceptance_criteria")).to be_empty
      expect(decision.attempts.sole.proposal.dig("acceptance_criteria", 0, "key")).to eq("replacement")
      expect(decision.attempts.sole.rejection_reason).to include("contract is already established")
      expect(run.acceptance_criteria.pluck(:key)).to eq([ "existing-outcome" ])
    end

    it "allows a parentKey'd decomposition even when the top-level contract is already established" do
      run, _request, decision = build_decision(with_acceptance: true)
      params = decision_params(
        summary: "Decompose the existing outcome.",
        next_step: step("diagnosis.md", mode: "diagnosis", addresses_criteria: [ "existing-outcome-sub" ]),
        acceptance_criteria: [ { key: "existing-outcome-sub", content: "Sub-goal.", parent_key: "existing-outcome" } ]
      )

      result = described_class.call(decision:, params:)

      expect(result).to eq({ accepted: true })
      child = run.acceptance_criteria.find_by!(key: "existing-outcome-sub")
      expect(child.parent.key).to eq("existing-outcome")
    end

    it "rejects, then escalates, an initial decision that omits the acceptance contract" do
      run, _request, decision = build_decision(with_acceptance: false)
      params = decision_params(summary: "Start diagnosis.", next_step: step("diagnosis.md", mode: "diagnosis"))

      first = described_class.call(decision:, params: params.deep_dup)

      expect(first[:accepted]).to be(false)
      expect(first[:error]).to include("omitted the acceptance contract")
      assert_empty run.chaperone_reviews
    end

    it "rejects, then escalates, a decision that completes the run after a blocked worker handoff" do
      run, request, decision = build_decision
      request.update!(tags: %w[planner worker-turn-followup evidence-blocked])
      params = decision_params(summary: "No executable steps remain.", next_step: nil)

      results = Array.new(described_class::MAX_REJECTED_DECISION_ATTEMPTS) { described_class.call(decision:, params: params.deep_dup) }

      expect(results.last).to eq({ accepted: true, escalated: true })
      assert_equal "awaiting_chaperone", decision.reload.status
      assert_equal "planner", run.chaperone_reviews.last.subject_type
    end

    it "is a no-op once the decision has already been finalized" do
      run, _request, decision = build_decision
      described_class.call(decision:, params: decision_params(summary: "Done.", next_step: step("verify.md", mode: "verification")))

      result = described_class.call(decision:, params: decision_params(summary: "Different.", next_step: step("other.md", mode: "verification")))

      expect(result).to eq({ accepted: true })
      assert_equal "verify.md", run.spawn_requests.open_only.find_by!(requested_role: "worker").scope
    end
  end

  describe "outcome: needs_context" do
    it "resolves and returns the requested context" do
      run, _request, decision = build_decision
      Orchestrator::ArtifactStore.write(run.target_root, run.run_id, "diagnosis.md", "Confirmed boundary: admin session was missing.")
      params = decision_params(
        outcome: "needs_context", summary: "Need the diagnosis.",
        context_request: { source: "artifact", reference: "diagnosis.md", question: "What boundary?", offset: nil, max_chars: 2_000 }
      )

      result = described_class.call(decision:, params:)

      expect(result[:accepted]).to be(true)
      expect(result[:context][:content]).to include("admin session was missing")
      assert_equal 1, decision.reload.context_requests.length
    end

    it "rejects an identical repeated context request" do
      run, _request, decision = build_decision
      Orchestrator::ArtifactStore.write(run.target_root, run.run_id, "diagnosis.md", "content")
      request_hash = { source: "artifact", reference: "diagnosis.md", question: "What boundary?", offset: nil, max_chars: 2_000 }
      described_class.call(decision:, params: decision_params(outcome: "needs_context", summary: "Need it.", context_request: request_hash))

      result = described_class.call(decision:, params: decision_params(outcome: "needs_context", summary: "Need it again.", context_request: request_hash))

      expect(result[:accepted]).to be(false)
      expect(result[:error]).to include("already made")
    end

    it "falls back to safe diagnosis when the requested context is unavailable" do
      run, _request, decision = build_decision
      params = decision_params(
        outcome: "needs_context", summary: "Need the diagnosis.",
        context_request: { source: "artifact", reference: "missing.md", question: "What?", offset: nil, max_chars: 2_000 }
      )

      result = described_class.call(decision:, params:)

      expect(result).to eq({ accepted: true, escalated: true })
      assert_equal "completed", decision.reload.status
      assert_equal "initial-diagnosis.md", run.spawn_requests.open_only.find_by!(requested_role: "worker").scope
    end

    it "falls back to safe diagnosis instead of trying again after the previous context was unavailable" do
      run, _request, decision = build_decision
      described_class.call(
        decision:,
        params: decision_params(
          outcome: "needs_context", summary: "Need it.",
          context_request: { source: "artifact", reference: "missing-1.md", question: "?", offset: nil, max_chars: 1_000 }
        )
      )
      decision.update!(status: "running") # undo the safe-diagnosis completion so the next call still routes through needs_context

      result = described_class.call(
        decision:,
        params: decision_params(
          outcome: "needs_context", summary: "Need it still.",
          context_request: { source: "artifact", reference: "missing-2.md", question: "?", offset: nil, max_chars: 1_000 }
        )
      )

      expect(result).to eq({ accepted: true, escalated: true })
    end
  end

  describe "outcome: needs_stronger_model" do
    it "queues chaperone for the small tier" do
      run, _request, decision = build_decision
      params = decision_params(outcome: "needs_stronger_model", summary: "This needs stronger reasoning.")

      result = described_class.call(decision:, params:)

      expect(result).to eq({ accepted: true })
      assert_equal "awaiting_chaperone", decision.reload.status
      assert_equal "planner", run.chaperone_reviews.last.subject_type
    end

    it "falls back to safe diagnosis for the strong tier" do
      run, request, decision = build_decision
      request.update!(model_tier: "strong")
      params = decision_params(outcome: "needs_stronger_model", summary: "This needs stronger reasoning.")

      result = described_class.call(decision:, params:)

      expect(result).to eq({ accepted: true })
      assert_equal "completed", decision.reload.status
      assert_empty run.chaperone_reviews
    end
  end

  def decision_params(outcome: "decision", summary:, next_step: nil, following_steps: [], context_request: nil, acceptance_criteria: [], acceptance_updates: [])
    {
      outcome:, summary:, next_step:, following_steps:, context_request:,
      acceptance_criteria:, acceptance_updates:
    }
  end

  def step(artifact, mode: "diagnosis", success_check: "Confirm the expected behavior.", write_scope: "source_protected",
           allowed_paths: [], evidence_refs: [], addresses_criteria: [ "existing-outcome" ])
    { owner: "worker", artifact:, success_check:, mode:, write_scope:, allowed_paths:, evidence_refs:, addresses_criteria: }
  end

  def build_decision(with_acceptance: true)
    workspace = Workspace.create!(name: "planner-submission-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s)
    run = workspace.runs.create!(
      run_id: "planner-submission-#{SecureRandom.hex(4)}", task: "Complete the workflow",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
    request = run.spawn_requests.create!(
      asked_by: "worker", scope: "workflow-plan.md", text: "Choose the next step.",
      requested_role: "planner", priority: "blocking", status: "fulfilled", fulfilled_by: "planner_decision_job"
    )
    decision = PlannerDecision.create!(run:, spawn_request: request, status: "running")
    if with_acceptance
      AcceptanceCriterion.create!(
        run_id: run.run_id, key: "existing-outcome", status: "verified",
        content: "Existing test outcome", evidence_ref: "Gemfile"
      )
    end
    [ run, request, decision ]
  end
end

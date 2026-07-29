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
        summary: "Implement it.",
        next_step: step("fix.md", mode: "implementation", write_scope: "scoped_changes", evidence_refs: [])
      )

      result = described_class.call(decision:, params:)

      expect(result[:accepted]).to be(false)
      expect(result[:error]).to eq("nextStep: implementation step requires at least one evidenceRef")
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
        error: 'nextStep: artifact must be a filename only, without a path prefix: "artifacts/phone-demo-baseline.md"'
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
        summary: "Implement it.",
        next_step: step("fix.md", mode: "implementation", write_scope: "scoped_changes", evidence_refs: [])
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
        summary: "Implement it.",
        next_step: step("fix.md", mode: "implementation", write_scope: "scoped_changes", evidence_refs: [])
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

  describe "plan approval gate" do
    it "opens a blocking plan-approval question instead of dispatching the first scoped_changes step, and suppresses jobs" do
      run, _request, decision = build_decision(managed: true)
      params = decision_params(
        summary: "Implement the fix.",
        next_step: step("fix.md", mode: "implementation", write_scope: "scoped_changes", evidence_refs: [ "diagnosis.md" ])
      )

      result = described_class.call(decision:, params:)

      expect(result).to eq({ accepted: true })
      assert_equal "completed", decision.reload.status
      question = UserQuestion.plan_approval.find_by!(run_id: run.run_id)
      expect(question).to have_attributes(priority: "blocking", status: "open")
      expect(question.context).to include("Complete the workflow").and include("fix.md")
      expect(question.gated_next_step).to include("artifact" => "fix.md", "mode" => "implementation")
      expect(question.gated_following_steps).to eq([])
      assert_empty run.spawn_requests.open_only.where(requested_role: "worker")
      assert_equal "awaiting_user_feedback", Orchestrator::TickState.latest(run.run_id)[:phase]
      expect(PublishUserQuestionJob).to have_been_enqueued.with(question.id)
    end

    it "does not re-ask once the first plan-approval question has been granted real approval, and dispatches the next scoped_changes step" do
      run, _request, decision = build_decision(managed: true)
      described_class.call(
        decision:, params: decision_params(
          summary: "Implement the fix.",
          next_step: step("fix.md", mode: "implementation", write_scope: "scoped_changes", evidence_refs: [ "diagnosis.md" ])
        )
      )
      # Only Orchestrator::ApplyReplyReceivedDecision's "approved" action
      # ever adds this tag (see Orchestrator::PlanApprovalQuestion.applicable?)
      # -- merely being answered is not enough since an explain/revise round
      # answers a question too without granting the gate.
      question = UserQuestion.plan_approval.find_by!(run_id: run.run_id)
      question.update!(status: "answered", answered_by: "reply_received", answer_text: "approved", tags: question.tags + [ "granted" ])

      next_request = run.spawn_requests.create!(
        asked_by: "worker", scope: "workflow-plan.md", text: "Choose the next step.",
        requested_role: "planner", priority: "blocking", status: "fulfilled", fulfilled_by: "planner_decision_job"
      )
      next_decision = PlannerDecision.create!(run:, spawn_request: next_request, status: "running")
      result = described_class.call(
        decision: next_decision, params: decision_params(
          summary: "Continue implementing.",
          next_step: step("fix-2.md", mode: "implementation", write_scope: "scoped_changes", evidence_refs: [ "diagnosis.md" ])
        )
      )

      expect(result).to eq({ accepted: true })
      assert_equal 1, UserQuestion.plan_approval.where(run_id: run.run_id).count
      assert_equal "fix-2.md", run.spawn_requests.open_only.find_by!(requested_role: "worker").scope
    end

    it "never gates a diagnosis or verification step" do
      run, _request, decision = build_decision(managed: true)

      described_class.call(decision:, params: decision_params(summary: "Diagnose.", next_step: step("diagnosis.md", mode: "diagnosis")))

      assert_empty UserQuestion.plan_approval.where(run_id: run.run_id)
      assert_equal "diagnosis.md", run.spawn_requests.open_only.find_by!(requested_role: "worker").scope
    end

    it "does not gate an unmanaged run (no answer channel exists)" do
      run, _request, decision = build_decision(managed: false)
      params = decision_params(
        summary: "Implement the fix.",
        next_step: step("fix.md", mode: "implementation", write_scope: "scoped_changes", evidence_refs: [ "diagnosis.md" ])
      )

      result = described_class.call(decision:, params:)

      expect(result).to eq({ accepted: true })
      assert_empty UserQuestion.plan_approval.where(run_id: run.run_id)
      assert_equal "fix.md", run.spawn_requests.open_only.find_by!(requested_role: "worker").scope
    end

    it "does not raise or double-block when a blocking question is already open for another reason" do
      run, _request, decision = build_decision(managed: true)
      UserQuestion.create!(run_id: run.run_id, asked_by: "chaperone", scope: "workflow-plan.md", priority: "blocking", text: "Continue or stop?")
      params = decision_params(
        summary: "Implement the fix.",
        next_step: step("fix.md", mode: "implementation", write_scope: "scoped_changes", evidence_refs: [ "diagnosis.md" ])
      )

      result = described_class.call(decision:, params:)

      expect(result).to eq({ accepted: true })
      assert_equal 1, run.user_questions.open_only.where(priority: "blocking").count
      assert_empty UserQuestion.plan_approval.where(run_id: run.run_id)
    end

    it "pins the acceptance branch even though the gated step is never dispatched" do
      run, _request, decision = build_decision(managed: true, with_acceptance: false)
      AcceptanceCriterion.create!(run_id: run.run_id, key: "pending-outcome", status: "pending", content: "Pending outcome")
      params = decision_params(
        summary: "Implement the fix.",
        next_step: step("fix.md", mode: "implementation", write_scope: "scoped_changes", evidence_refs: [ "diagnosis.md" ], addresses_criteria: [ "pending-outcome" ])
      )

      described_class.call(decision:, params:)

      criterion = run.acceptance_criteria.find_by!(key: "pending-outcome")
      expect(criterion.status).to eq("in_progress")
      expect(run.reload.active_branch_key).to eq("pending-outcome")
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

  def build_decision(with_acceptance: true, managed: false)
    workspace = Workspace.create!(name: "planner-submission-#{SecureRandom.hex(4)}", root_path: Rails.root.to_s)
    run_attrs = { run_id: "planner-submission-#{SecureRandom.hex(4)}", task: "Complete the workflow",
                  target_root: workspace.root_path, launcher_variant: "claude", status: "running" }
    if managed
      suffix = SecureRandom.hex(4)
      run_attrs.merge!(worktree_name: "submission-#{suffix}", branch_name: "workflow/submission-#{suffix}")
    end
    run = workspace.runs.create!(run_attrs)
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

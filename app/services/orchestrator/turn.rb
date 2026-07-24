module Orchestrator
  # Ports scripts/worker-turn.ts and scripts/planner-turn.ts. Snake_case throughout -- camelizing for the
  # wire only happens at each MCP tool's McpTools::ToolResponse.structured
  # call (see Orchestrator::TickState for the DB read/write boundary).
  module Turn
    module_function

    PLANNER_FOLLOWUP_SCOPE = "workflow-plan.md"

    # task is part of the MCP tool's input schema for API-surface
    # consistency with the other turn tools, but -- matching
    # scripts/worker-turn.ts exactly -- is never actually read here.
    def run_worker_turn(run_id:, role:, nickname:, scope:, result:, evidence_outcome: nil, evidence_citations: [], diagnosis_findings: nil, now: Time.current, previous_state: nil)
      DiagnosisEvidenceGate.validate!(run_id:, nickname:, scope:, evidence_outcome:, evidence_citations:)
      StructuredDiagnosisFindings.persist!(run_id:, nickname:, scope:, findings: diagnosis_findings) if diagnosis_findings.present?
      following_steps = previous_state&.dig(:following_steps) || []
      active_worker_ids = Worker.where(run_id: run_id, status: "running").pluck(:worker_id).to_set

      if (review = record_step_attempt(run_id:, nickname:, result:, evidence_outcome:, evidence_citations:))
        next_state = (previous_state || TickState.default_state(run_id)).merge(
          phase: "planning", last_plan_summary: "Strong chaperone is reviewing repeated worker failures.",
          last_updated_at: now.utc.iso8601(3)
        )
        return { planner_request: nil, chaperone_review: { review_id: review.review_id }, next_state: next_state }
      end

      run = Run.find_by!(run_id: run_id)
      active_branch_open = run.active_branch_key.present? && !AcceptanceCriteria.branch_resolved?(run:, branch_key: run.active_branch_key)

      # A completed node may only promote its next sibling after the current
      # acceptance branch is resolved. Otherwise the planner must insert the
      # next child of this branch (for example, measure -> repair -> verify)
      # ahead of later verifier siblings.
      if completed_result?(result) && following_steps.any? && !active_branch_open
        next_step, *remaining_steps = following_steps
        summary = "#{nickname} completed #{scope}. Rails promoted the next previously planned step without another planner call."
        promoted = run_planner_turn(
          run_id:, summary:, next_step:, following_steps: remaining_steps, now:, previous_state:
        )
        return promoted.merge(planner_request: nil, promoted_preplanned_step: true)
      end

      # A follow-up planner request is a repeatable recovery ask, not a
      # one-time artifact -- an 'open' request is safe to reuse
      # unconditionally, but a 'fulfilled' one only still represents
      # "already being handled" while the planner it spawned is still
      # active.
      existing_request = SpawnRequest
        .where(run_id: run_id, requested_role: "planner", scope: PLANNER_FOLLOWUP_SCOPE)
        .where.not(status: "dismissed")
        .detect do |request|
          request.status == "open" ||
            (request.fulfilled_worker_id.present? && active_worker_ids.include?(request.fulfilled_worker_id)) ||
            PlannerDecision.active.exists?(spawn_request_id: request.request_id)
        end

      planner_request = existing_request || SpawnRequest.create!(
        run_id: run_id,
        asked_by: "worker",
        scope: PLANNER_FOLLOWUP_SCOPE,
        text: "Decide the next nextStep (usually the head of followingSteps, but reconsider it against the reported " \
          "result) and the new followingSteps, then publish them with planner_turn. If blocked on a user decision, " \
          "call append_user_question.",
        context: [
          "Worker #{nickname} (role #{role}) reported this result for run #{run_id}, scope #{scope}: #{result}",
          (evidence_outcome.present? ? "Evidence outcome: #{evidence_outcome}; citations: #{Array(evidence_citations).join(', ')}." : nil),
          "Current followingSteps queue (JSON, decided by the previous planner_turn call): #{following_steps.to_json}"
        ].compact.join(" "),
        requested_role: "planner",
        priority: "blocking",
        tags: [ "planner", PLANNER_FOLLOWUP_SCOPE, "worker-turn-followup", ("evidence-#{evidence_outcome}" if evidence_outcome.present?) ].compact
      )

      # phase/tick_count/last_plan_summary/last_stall_finding/following_steps
      # are all owned by planner_turn and orchestrator-turn's stall
      # detection -- worker_turn only requests the follow-up planner and
      # reports what it saw, so it carries all of this forward untouched.
      next_state = {
        run_id: run_id,
        phase: previous_state&.dig(:phase) || "starting",
        tick_count: previous_state&.dig(:tick_count) || 0,
        last_stall_finding: previous_state&.dig(:last_stall_finding),
        last_plan_summary: previous_state&.dig(:last_plan_summary),
        pending_spawn_keys: previous_state&.dig(:pending_spawn_keys) || [],
        following_steps: following_steps,
        last_updated_at: now.utc.iso8601(3)
      }

      { planner_request: { request_id: planner_request.request_id }, next_state: next_state }
    end

    def completed_result?(result)
      result.to_s.match?(/\A\s*\[DONE\]/i)
    end
    private_class_method :completed_result?

    # Covers every execution mode, not only diagnosis -- a worker that
    # correctly reports [BLOCKED]/[FAILED] via worker_turn must be exactly
    # as visible to ChaperoneTrigger as one whose process dies outright
    # (see WorkerReconcileJob#record_failed_attempt, which was already
    # mode-agnostic). Diagnosis alone keeps its stricter done/evidence
    # coupling -- see step_attempt_outcome.
    def record_step_attempt(run_id:, nickname:, result:, evidence_outcome:, evidence_citations:)
      worker = Worker.where(run_id:, nickname:).order(created_at: :desc).first
      request = worker && SpawnRequest.find_by(fulfilled_worker_id: worker.worker_id)
      return unless request

      mode = SpawnRequestedWorkers.execution_mode(request).presence || "unknown"
      outcome = step_attempt_outcome(result:, evidence_outcome:, mode:)
      lineage_key = request.lineage_key.presence || request.scope
      attempt = StepAttempt.create!(
        run_id:, spawn_request: request, worker_id: worker.worker_id, lineage_key:, mode:,
        outcome:, result:, evidence_outcome:, evidence_citations:
      )
      return unless outcome.in?(%w[blocked failed])

      ChaperoneTrigger.call(attempt)
    end
    private_class_method :record_step_attempt

    # Diagnosis requires evidenceOutcome=confirmed before a [DONE] report
    # counts as actually done -- DiagnosisEvidenceGate already enforces the
    # citation discipline behind that claim. Other modes have no such
    # evidence contract, so a bare [DONE] is trusted at face value there.
    def step_attempt_outcome(result:, evidence_outcome:, mode:)
      done = result.to_s.match?(/\A\s*\[DONE\]/i)
      return "done" if done && (mode != "diagnosis" || evidence_outcome == "confirmed")
      return "failed" if result.to_s.match?(/\A\s*\[FAILED\]/i)

      "blocked"
    end
    private_class_method :step_attempt_outcome

    def run_planner_turn(run_id:, summary:, next_step:, following_steps:, now: Time.current, previous_state: nil)
      StepPolicy.validate_plan!(run_id:, next_step:, following_steps:)
      # Single source of truth for "next_step became the active step, so
      # record which criteria it addresses" -- covers both a live planner
      # decision and Rails auto-promoting a previously queued followingSteps
      # item after a [DONE] result (see run_worker_turn) without a second
      # planner call. Only the former used to call this, which silently
      # dropped the addressesCriteria the planner already attached to every
      # followingSteps item, leaving auto-promoted steps invisible to
      # AcceptanceCriteriaWorkers and to ChaperoneTrigger's criterion join.
      run = Run.find_by!(run_id: run_id)
      enforce_branch_progression!(run:, next_step:)
      Orchestrator::AcceptanceCriteria.record_step!(run:, next_step: next_step)
      planner_blockers = Orchestrator::AcceptanceCriteria.planner_blockers(run_id: run_id)
      if next_step.nil? && planner_blockers.any?
        raise ArgumentError, "Cannot complete run while acceptance criteria remain pending: #{planner_blockers.join(', ')}"
      end

      # An open blocking question means the run is waiting on the user, not
      # the planner -- publishing new jobs here would dispatch workers behind
      # a UI that still reads "awaiting_user_feedback", so no new work may be queued
      # until the question is answered.
      has_open_blocking_question = UserQuestion.exists?(run_id: run_id, status: "open", priority: "blocking")
      jobs =
        if has_open_blocking_question
          []
        else
          Planner.publish_planner_jobs(
            run_id: run_id,
            summary: summary,
            plan: { summary: summary, next_step: next_step, following_steps: following_steps }
          )
        end
      # The planner that is submitting this decision remains registered as
      # running until its CLI process exits. It is not work that should keep
      # the run alive after a nil next_step, otherwise every completed planner
      # turn becomes waiting_on_workers and the stall recovery loop restarts.
      active_executor_exists = Worker.where(run_id: run_id, status: "running").where.not(role: "planner").exists?
      # A criterion can be unresolved (ready_for_verification) with no
      # active_executor yet -- the verifier SpawnRequest this same update
      # just created hasn't been dispatched by SpawnRequestedWorkers yet.
      # The run must not read "completed" in that gap.
      unresolved_criteria_exist = Orchestrator::AcceptanceCriteria.completion_blockers(run_id: run_id).any?
      completion_phase =
        if has_open_blocking_question
          "awaiting_user_feedback"
        elsif next_step
          "planning"
        elsif active_executor_exists || unresolved_criteria_exist
          "waiting_on_workers"
        else
          "completed"
        end

      next_state = {
        run_id: run_id,
        # next_step: nil only means "completed" when nothing is still in
        # flight. A recovery planner can legitimately publish no new
        # immediate handoff because an existing worker should continue
        # uninterrupted; in that case the run must stay
        # waiting_on_workers rather than flipping completed.
        phase: completion_phase,
        tick_count: (previous_state&.dig(:tick_count) || 0) + 1,
        last_plan_summary: summary,
        pending_spawn_keys: ((previous_state&.dig(:pending_spawn_keys) || []) + Planner.build_pending_spawn_keys(run_id: run_id, jobs: jobs)).uniq,
        following_steps: following_steps,
        last_stall_finding: previous_state&.dig(:last_stall_finding),
        last_updated_at: now.utc.iso8601(3)
      }

      { jobs: jobs, next_state: next_state }
    end

    def enforce_branch_progression!(run:, next_step:)
      return unless next_step

      branch_key = AcceptanceCriteria.branch_key_for_step(run:, step: next_step)
      return unless branch_key

      active_key = run.active_branch_key
      if active_key.present? && !AcceptanceCriteria.branch_resolved?(run:, branch_key: active_key) && branch_key != active_key
        raise ArgumentError, "Cannot leave active acceptance branch #{active_key} before it resolves"
      end

      run.update!(active_branch_key: branch_key) if active_key != branch_key
    end
    private_class_method :enforce_branch_progression!

    # A run can go dead without ever looking "stalled": a worker stops
    # (crash, or a clean exit whose worker_turn call never landed) without
    # producing a follow-up spawn request.
    def build_dead_end_finding(run_id:, following_steps:)
      [
        "Run #{run_id} has no active workers and no open spawn requests, but was not marked completed.",
        "following_steps queue at last check: #{following_steps.to_json}",
        "The most recent worker likely stopped without completing its worker_turn handoff (crashed, or the call " \
          "failed) -- inspect its last known report/artifact and decide whether to retry, fix, or escalate to the user."
      ].join(" ")
    end
    public :build_dead_end_finding
  end
end

module Orchestrator
  module ApplyChaperoneDecision
    module_function

    def call(review:, action:, summary:, revised_instruction: nil, planner_tier: nil, context_requests: nil, blocker_key: nil)
      raise ArgumentError, "Unknown chaperone action" unless ChaperoneReview::ACTIONS.include?(action)

      return apply_planner_decision(review:, action:, summary:, revised_instruction:) if review.subject_type == "planner"

      attempt = StepAttempt.where(attempt_id: review.step_attempt_ids).order(:created_at).last!
      source = attempt.spawn_request
      ChaperoneReview.transaction do
        case action
        when "continue_small", "promote"
          # execution_mode/write_scope/allowed_paths are carried forward
          # explicitly rather than left to SpawnRequestedWorkers.execution_mode's
          # text-parsing fallback -- a revised_instruction replaces source.text
          # wholesale and would otherwise silently drop the "Execution mode: ..."
          # sentence that fallback depends on.
          SpawnRequest.create!(
            run_id: review.run_id, asked_by: "chaperone", scope: source.scope,
            text: revised_instruction.presence || source.text,
            context: "Chaperone #{action}: #{summary}", requested_role: source.requested_role,
            priority: "blocking", tags: source.tags + [ "chaperone", action ],
            lineage_key: review.lineage_key, model_tier: action == "promote" ? "strong" : "small",
            execution_mode: source.execution_mode, write_scope: source.write_scope,
            allowed_paths: source.allowed_paths
          )
        when "stop"
          # A stopped retry means only that the *current* execution envelope
          # is exhausted. It is not, by itself, an operator decision. Return
          # the concrete evidence to the planner so it can authorize a narrow
          # follow-up (for example a non-protected endpoint/configuration fix)
          # before it considers asking the user.
          queue_diagnosis_replan!(review:, source:, summary:, planner_tier:, context_requests:, blocker_key:)
        end
        review.update!(status: "completed", action:, summary:, completed_at: Time.current)
        StepAttempt.where(attempt_id: review.step_attempt_ids).update_all(
          chaperone_status: "completed", chaperone_action: action, chaperone_summary: summary
        )
      end
      TickRunJob.perform_later
    end

    # A ChaperoneReview that itself fails (its model call errored, or the
    # process running it was killed) never calls submit_chaperone_decision,
    # so nothing else ever moves its subject (a PlannerDecision, still
    # "awaiting_chaperone", or step attempts still "queued") out of an
    # active state. Left alone, TickRunJob's stall recovery treats that
    # subject as still in flight forever and the run silently stops making
    # progress. Escalate the same way a chaperone "stop" outcome would:
    # mark the subject failed and ask the operator, rather than retrying or
    # promoting on Rails' own initiative.
    def handle_review_failure(review:)
      return unless review.status == "failed"

      scope =
        if review.subject_type == "planner"
          decision = PlannerDecision.find_by(decision_id: review.subject_id)
          return if decision.nil? || !decision.status.in?(PlannerDecision::ACTIVE_STATUSES)

          decision.update!(
            status: "failed",
            error: "Chaperone review failed before submitting a decision: #{review.summary}",
            completed_at: Time.current
          )
          decision.spawn_request&.scope
        else
          attempts = StepAttempt.where(attempt_id: review.step_attempt_ids)
          return if attempts.empty? || attempts.where(chaperone_status: "failed").exists?

          attempts.update_all(chaperone_status: "failed", chaperone_summary: review.summary)
          attempts.order(:created_at).last&.spawn_request&.scope
        end

      question_text = review.subject_type == "planner" ? planner_stop_question : diagnosis_stop_question
      UserQuestion.create!(
        run_id: review.run_id, asked_by: "chaperone", scope: scope.presence || "run",
        text: "The chaperone review could not complete (it failed before reaching a decision). #{question_text}",
        context: stop_question_context(review:, summary: review.summary), priority: "blocking",
        tags: %w[chaperone execution_failed]
      )
      review.run.publish_phase!(phase: "blocked_on_user", owner: "chaperone", summary: review.summary)
      TickRunJob.perform_later
    end

    def apply_planner_decision(review:, action:, summary:, revised_instruction:)
      decision = PlannerDecision.find_by!(decision_id: review.subject_id)
      request = decision.spawn_request
      ChaperoneReview.transaction do
        case action
        when "continue_small", "promote"
          request.update!(
            status: "open", fulfilled_by: nil, fulfilled_at: nil, fulfillment_note: nil,
            fulfilled_worker_id: nil, model_tier: action == "promote" ? "strong" : "small",
            text: revised_instruction.presence || request.text,
            context: [ request.context, "Chaperone #{action}: #{summary}" ].compact.join(" ")
          )
          decision.update!(status: "failed", error: "Chaperone requested a new #{request.model_tier} planner attempt.", completed_at: Time.current)
        when "stop"
          decision.update!(status: "failed", error: "Chaperone stopped planner promotion: #{summary}", completed_at: Time.current)
          UserQuestion.create!(
            run_id: review.run_id, asked_by: "chaperone", scope: request.scope,
            text: planner_stop_question,
            context: stop_question_context(review:, summary:), priority: "blocking",
            tags: %w[chaperone planner stopped]
          )
          review.run.publish_phase!(phase: "blocked_on_user", owner: "chaperone", summary: summary)
        end
        review.update!(status: "completed", action:, summary:, completed_at: Time.current)
      end
      TickRunJob.perform_later
    end
    private_class_method :apply_planner_decision

    def diagnosis_stop_question
      "Should this run stop here, retry diagnosis within its current scope, or use a different bounded approach?"
    end
    private_class_method :diagnosis_stop_question

    BLOCKER_KEY_PATTERN = /\A[a-z0-9]+(-[a-z0-9]+)*\z/

    def queue_diagnosis_replan!(review:, source:, summary:, planner_tier:, context_requests:, blocker_key:)
      unless planner_tier.present?
        UserQuestion.create!(
          run_id: review.run_id, asked_by: "chaperone", scope: source.scope,
          text: diagnosis_stop_question,
          context: stop_question_context(review:, summary:), priority: "blocking",
          tags: %w[chaperone stopped]
        )
        review.run.publish_phase!(phase: "blocked_on_user", owner: "chaperone", summary: summary)
        return
      end

      tier = planner_tier.presence || "small"
      raise ArgumentError, "Chaperone planner tier must be small or strong" unless %w[small strong].include?(tier)
      raise ArgumentError, "A repair planner requires a blockerKey identifying the blocking condition" if blocker_key.blank?
      raise ArgumentError, "blockerKey must be a lowercase-hyphenated slug" unless blocker_key.match?(BLOCKER_KEY_PATTERN)

      if bounded_replan_already_requested?(review:, blocker_key:, tier:)
        UserQuestion.create!(
          run_id: review.run_id, asked_by: "chaperone", scope: source.scope,
          text: "The evidence-backed repair plan for this blocker (\"#{blocker_key}\", #{tier} tier) was already attempted for this lineage. What should the run do next?",
          context: stop_question_context(review:, summary:), priority: "blocking",
          tags: %w[chaperone stopped repair_replan_exhausted]
        )
        review.run.publish_phase!(phase: "blocked_on_user", owner: "chaperone", summary: summary)
        return
      end

      latest_attempt = StepAttempt.where(attempt_id: review.step_attempt_ids).order(:created_at).last
      raise ArgumentError, "A repair planner requires at least one chaperone-selected context request" if Array(context_requests).empty?
      selected_context = resolve_chaperone_context!(review:, context_requests:)
      SpawnRequest.create!(
        run_id: review.run_id,
        asked_by: "chaperone",
        scope: Turn::PLANNER_FOLLOWUP_SCOPE,
        text: "Choose one bounded next step from the chaperone's stopped retry. " \
          "Use the supplied chaperone-selected context. Prefer a safe, exact-path implementation or infrastructure fix when the evidence identifies one; " \
          "ask the operator only if no such bounded step can resolve the blocker.",
        context: [
          "Chaperone stopped the current retry: #{summary}",
          "Stopped request: role=#{source.requested_role}, scope=#{source.scope}, mode=#{source.execution_mode}, " \
            "writeScope=#{source.write_scope}, allowedPaths=#{source.allowed_paths.to_json}.",
          ("Latest worker report: #{latest_attempt.result}" if latest_attempt),
          selected_context.presence && "Chaperone-selected context:\n#{selected_context}"
        ].compact.join(" "),
        requested_role: "planner",
        model_tier: tier,
        priority: "blocking",
        tags: [ "planner", "chaperone", "stopped_retry", "replan", "blocker:#{blocker_key}" ],
        lineage_key: review.lineage_key
      )
      review.run.publish_phase!(phase: "planning", owner: "chaperone", summary: "Chaperone stopped the retry and requested a bounded replan: #{summary}")
    end
    private_class_method :queue_diagnosis_replan!

    # Scoped per (lineage, blocker, tier) rather than per lineage: the same
    # blocker recurring at the same tier means the replan already tried and
    # failed to fix it, so stop for real. A new blocker, or the same blocker
    # escalating from small to strong after a too-narrow small-tier envelope,
    # both get their own one-shot repair budget instead of being lumped
    # together as "this lineage already used its one replan."
    def bounded_replan_already_requested?(review:, blocker_key:, tier:)
      SpawnRequest.where(
        run_id: review.run_id,
        asked_by: "chaperone",
        requested_role: "planner",
        lineage_key: review.lineage_key,
        model_tier: tier
      ).where("tags LIKE ?", "%stopped_retry%").any? { |request| request.tags.include?("blocker:#{blocker_key}") }
    end
    private_class_method :bounded_replan_already_requested?

    def resolve_chaperone_context!(review:, context_requests:)
      Array(context_requests).map do |request|
        normalized = request.deep_symbolize_keys
        raise ArgumentError, "Chaperone context source is not permitted" unless %w[artifact run_context worker_log].include?(normalized[:source])

        resolved = PlannerContextResolver.resolve(run: review.run, context_request: normalized)
        "[#{resolved[:source]} #{resolved[:reference]}] #{resolved[:question]}\n#{resolved[:content]}"
      end.join("\n\n").first(12_000)
    end
    private_class_method :resolve_chaperone_context!

    def planner_stop_question
      "Should this run stop here, retry within its current scope, or expand to the protected work the planner proposed?"
    end
    private_class_method :planner_stop_question

    def stop_question_context(review:, summary:)
      trigger = review.trigger_reason.presence
      [ "Chaperone conclusion: #{summary}", ("Trigger: #{trigger}" if trigger) ].compact.join("\n\n")
    end
    private_class_method :stop_question_context
  end
end

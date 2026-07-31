module Orchestrator
  # Gates the first planner-proposed step in a run with write_scope ==
  # "scoped_changes" (the first time real code is about to be written) on
  # operator approval, via a blocking UserQuestion published to GitHub (an
  # issue before any PR exists -- see RunPublication#ensure_conversation_issue!).
  #
  # This fires once per run's lifetime, not once per phase: diagnosis and
  # verification steps (write_scope: "source_protected") never trigger it,
  # and once the operator has answered the first plan-approval question,
  # later scoped_changes steps proceed normally.
  module PlanApprovalQuestion
    module_function

    TAG = "plan-approval"
    SUMMARY_APPLIED_TAG = "summary_applied"
    TASK_LIMIT = 4_000
    DIAGNOSIS_LIMIT = 1_500
    DIAGNOSIS_ATTEMPTS = 2

    # Called from PlannerDecisionSubmission.handle_decision, strictly before
    # persist_decision! -- Turn.run_planner_turn's own has_open_blocking_question
    # check must see this row already created (same transaction, same
    # connection) to suppress dispatch for the gated step.
    def ask!(decision:, next_step:, following_steps:)
      run = decision.run
      return unless applicable?(run:, next_step:)

      question = UserQuestion.create!(
        run_id: run.run_id, asked_by: "planner", priority: "blocking",
        scope: next_step[:artifact].presence || "run",
        text: question_text, context: build_context(run:, next_step:), tags: [ TAG ],
        gated_next_step: next_step.deep_stringify_keys,
        gated_following_steps: Array(following_steps).map(&:deep_stringify_keys)
      )
      request_plan_summary!(run:, question:)
      question
    end

    # A reporter worker (the same role/persona that already writes
    # run-summary.md at finalization, see agent_personas/reporter.md)
    # translates the technical step above into plain language for the
    # operator. Scoped uniquely per question (not a fixed "plan-summary.md")
    # so a later explain/revise round's own reporter never collides with an
    # earlier one, and so TickRunJob's finalization-stage guard (scoped by
    # role+scope, see queue_finalization_worker) never confuses this with
    # the real end-of-run reporter. Orchestrator::TickRunJob#tick_run polls
    # for its completion and upgrades the question in place once it's done
    # -- this never blocks question creation itself, which is what
    # suppresses worker dispatch (see this method's header comment above).
    def request_plan_summary!(run:, question:)
      SpawnRequest.create!(
        run_id: run.run_id, asked_by: "planner", requested_role: "reporter", priority: "blocking",
        scope: plan_summary_scope(question), execution_mode: "diagnosis", write_scope: "source_protected",
        text: "Follow agent_personas/reporter.md's instructions.",
        tags: %w[reporter plan-summary]
      )
    end
    private_class_method :request_plan_summary!

    PLAN_SUMMARY_SCOPE_PREFIX = "plan-summary-"

    def plan_summary_scope(question)
      "#{PLAN_SUMMARY_SCOPE_PREFIX}#{question.question_id}.md"
    end

    # The single source of truth for recognizing a plan-summary scope --
    # McpTools::GetReporterContextTool uses this to compute its `stage`
    # field server-side, so agent_personas/reporter.md never has to infer
    # its own job by pattern-matching a filename convention itself.
    def plan_summary_scope?(scope)
      scope.to_s.start_with?(PLAN_SUMMARY_SCOPE_PREFIX)
    end

    # Polled from TickRunJob#tick_run every tick: cheap (at most one open
    # plan-approval question per run, see UserQuestion's own one-blocking-
    # question invariant), and idempotent via SUMMARY_APPLIED_TAG so a
    # reporter that finishes between ticks is only ever applied once. Never
    # blocks on the reporter -- if it hasn't completed yet, this is a no-op
    # and the question sits with its original generic wording until the
    # next tick finds it done.
    def apply_pending_summaries!(run)
      run.user_questions.open_only.plan_approval.each do |question|
        next if question.tags.include?(SUMMARY_APPLIED_TAG)

        reporter = Worker.where(run_id: run.run_id, role: "reporter", scope: plan_summary_scope(question))
          .where.not(handoff_completed_at: nil).first
        next unless reporter

        summary = read_plan_summary(run:, scope: plan_summary_scope(question))
        next if summary.blank?

        question.update!(text: "#{summary}\n\n#{question_text}", tags: (question.tags + [ SUMMARY_APPLIED_TAG ]).uniq)
        patch_github_comment!(run:, question:) if question.github_comment_id.present?
      end
    end

    def read_plan_summary(run:, scope:)
      Orchestrator::ArtifactStore.read(run.target_root, run.run_id, scope).strip
    rescue Errno::ENOENT
      nil
    end
    private_class_method :read_plan_summary

    def patch_github_comment!(run:, question:)
      Orchestrator::PullRequestResume.patch_comment!(run, question.github_comment_id, Orchestrator::RunPublication.build_question_body(question))
    rescue Orchestrator::PullRequestResume::Error => error
      Rails.logger.warn("PlanApprovalQuestion: failed to patch GitHub comment for question #{question.question_id}: #{error.message}")
    end
    private_class_method :patch_github_comment!

    def applicable?(run:, next_step:)
      return false unless next_step.present?
      # StepPolicy.validate! forces diagnosis/verification/recording to
      # source_protected -- scoped_changes only ever reaches here for
      # mode=implementation or mode=infrastructure. If that coupling ever
      # changes, this condition needs to change with it.
      return false unless next_step[:write_scope] == "scoped_changes"
      return false unless run.managed_worktree?
      return false if run.open_blocking_question?

      # Not "has a plan-approval question ever existed" -- a reply_received
      # explain/revise round answers one without granting approval (see
      # Orchestrator::ApplyReplyReceivedDecision), and the gate must be able
      # to re-fire on the resulting revised plan. Only an explicit approval
      # (tagged "granted" by ApplyReplyReceivedDecision.apply_approved!)
      # permanently satisfies this gate for the run's lifetime.
      !UserQuestion.where(run_id: run.run_id).plan_approval.where("tags LIKE ?", "%\"#{Orchestrator::ApplyReplyReceivedDecision::GRANTED_TAG}\"%").exists?
    end
    private_class_method :applicable?

    def question_text
      "Before any code is written on this run: does the plan below still match what you actually " \
      "asked for? Reply `approved` to continue, or reply with the correction."
    end
    private_class_method :question_text

    def build_context(run:, next_step:)
      [
        "### What you originally asked for\n```\n#{truncate(run.task, TASK_LIMIT)}\n```",
        "### The acceptance contract this run locked in (immutable)\n#{render_criteria(Orchestrator::AcceptanceCriteria.tree(run_id: run.run_id))}",
        diagnosis_section(run),
        "### The step about to run\n" \
          "- artifact: #{next_step[:artifact]}\n- mode: #{next_step[:mode]}\n- write_scope: #{next_step[:write_scope]}\n" \
          "- allowed_paths: #{Array(next_step[:allowed_paths]).presence&.join(', ') || 'none'}\n" \
          "- addresses_criteria: #{Array(next_step[:addresses_criteria]).join(', ')}\n" \
          "- success_check: #{next_step[:success_check]}",
        "### If this is wrong\nIf the step or the criteria above describe something other than your request, say so " \
          "in your reply. Note the top-level acceptance contract is immutable and this run is now committed to the " \
          "acceptance branch above -- a correction *within* that branch can still be planned, but if the contract " \
          "itself is wrong the right move is to stop this run and relaunch with a corrected task description."
      ].compact.join("\n\n")
    end
    private_class_method :build_context

    def render_criteria(nodes, depth: 0)
      nodes.map do |node|
        line = "#{"  " * depth}- [#{node[:status]}] #{node[:key]} — #{node[:content]}"
        children = Array(node[:children])
        children.any? ? "#{line}\n#{render_criteria(children, depth: depth + 1)}" : line
      end.join("\n")
    end
    private_class_method :render_criteria

    def diagnosis_section(run)
      attempts = run.step_attempts.where(mode: "diagnosis").order(created_at: :desc).limit(DIAGNOSIS_ATTEMPTS)
      return nil if attempts.empty?

      lines = attempts.map { |a| "- #{a.lineage_key} (#{a.outcome}): #{truncate(a.result, DIAGNOSIS_LIMIT)}" }
      "### What diagnosis found\n#{lines.join("\n")}"
    end
    private_class_method :diagnosis_section

    def truncate(value, limit)
      text = value.to_s
      text.length > limit ? "#{text.first(limit).rstrip}…" : text
    end
    private_class_method :truncate
  end
end

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
    TASK_LIMIT = 4_000
    DIAGNOSIS_LIMIT = 1_500
    DIAGNOSIS_ATTEMPTS = 2

    # Called from PlannerDecisionSubmission.handle_decision, strictly before
    # persist_decision! -- Turn.run_planner_turn's own has_open_blocking_question
    # check must see this row already created (same transaction, same
    # connection) to suppress dispatch for the gated step.
    def ask!(decision:, next_step:)
      run = decision.run
      return unless applicable?(run:, next_step:)

      UserQuestion.create!(
        run_id: run.run_id, asked_by: "planner", priority: "blocking",
        scope: next_step[:artifact].presence || "run",
        text: question_text, context: build_context(run:, next_step:), tags: [ TAG ]
      )
    end

    def applicable?(run:, next_step:)
      return false unless next_step.present?
      # StepPolicy.validate! forces diagnosis/verification/recording to
      # source_protected -- scoped_changes only ever reaches here for
      # mode=implementation or mode=infrastructure. If that coupling ever
      # changes, this condition needs to change with it.
      return false unless next_step[:write_scope] == "scoped_changes"
      return false unless run.managed_worktree?
      return false if run.open_blocking_question?

      !UserQuestion.where(run_id: run.run_id).plan_approval.exists?
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
      findings = RunContextEntry.where(run_id: run.run_id).where("entry_key LIKE ?", "diagnosis-findings-%")
      return nil if attempts.empty? && findings.empty?

      lines = attempts.map { |a| "- #{a.lineage_key} (#{a.outcome}): #{truncate(a.result, DIAGNOSIS_LIMIT)}" }
      lines += findings.map { |f| "- #{f.entry_key}: #{truncate(f.content, DIAGNOSIS_LIMIT)}" }
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

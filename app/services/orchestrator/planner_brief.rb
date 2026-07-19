module Orchestrator
  module PlannerBrief
    module_function

    TEXT_LIMIT = 6_000

    def build(run:, request:, additional_context: [], model_tier: :small)
      state = TickState.latest(run.run_id)
      payload = {
        run: { id: run.run_id, task: truncate(run.task), target_root: run.target_root },
        request: {
          asked_by: request.asked_by,
          scope: request.scope,
          instruction: truncate(request.text),
          context: truncate(request.context)
        },
        workflow: {
          phase: state[:phase],
          last_plan_summary: truncate(state[:last_plan_summary]),
          following_steps: state[:following_steps],
          completion_blockers: RunContext.completion_blockers(run_id: run.run_id)
        },
        run_context: RunContext.snapshot(run_id: run.run_id),
        open_questions: run.user_questions.where(status: "open").order(:asked_at).limit(3).map(&:as_diagnostic_json),
        recent_attempts: run.step_attempts.order(created_at: :desc).limit(5).reverse.map do |attempt|
          {
            lineage_key: attempt.lineage_key,
            mode: attempt.mode,
            outcome: attempt.outcome,
            result: truncate(attempt.result),
            chaperone_action: attempt.chaperone_action
          }
        end,
        latest_chaperone: run.chaperone_reviews.where(status: "completed").order(completed_at: :desc).first&.then do |review|
          {
            subject_type: review.subject_type,
            action: review.action,
            trigger: truncate(review.trigger_reason),
            conclusion: truncate(review.summary)
          }
        end,
        recent_transitions: TickState.history(run.run_id, limit: 6)[:entries].map do |entry|
          entry.slice(:tick_count, :phase, :last_plan_summary, :following_steps)
        end,
        requested_context: additional_context
      }

      <<~PROMPT
        You are a workflow planner. Make exactly one bounded orchestration decision from the Rails-prepared evidence below.
        Do not inspect files, call tools, update memory, or execute work. Return only the JSON object required by the schema.
        Choose at most one nextStep. Keep followingSteps ordered and limited to concrete work already justified by the evidence.
        On the initial decision, define a concise acceptanceCriteria contract derived directly from the user's requested
        outcomes. Criteria describe observable outcomes, not implementation steps. On later decisions return acceptanceCriteria=[];
        the established contract is immutable. Use acceptanceUpdates only when supplied worker evidence positively satisfies
        an existing criterion. A verified update requires a workspace-relative evidenceRef; blocked work, source edits alone,
        estimates, and absence of errors are not positive verification. Waive only when the user explicitly authorized it.
        Never return nextStep=null while completion_blockers remain after applying justified acceptanceUpdates.
        A diagnosis step must be artifact_only. An implementation step must name exact workspace-relative file paths in
        allowedPaths. An exact file path names one file: it must not end in "/" and must not contain glob characters
        (*, ?, [, ], {, or }). Directory paths such as "front/" and patterns such as "front/**/*.ts" are invalid.
        Use mode=recording for running a demo or collecting recording/timing artifacts, even when owner=infrastructure;
        recording and verification must use writeScope=artifact_only and allowedPaths=[]. Use mode=infrastructure only
        when the step is authorized to modify exact infrastructure files with writeScope=scoped_changes.
        When the run has a performance objective, every proposed step's successCheck must explicitly retain it. A
        verification step must require evidence that the result is faster than the baseline; merely collecting or
        comparing timings does not verify the requested improvement.
        If the task is ambiguous and no known source contains the missing detail, choose a bounded diagnosis step that locates
        the target and measures a baseline. Do not use needs_context to search the repository or repeatedly ask for absent facts.
        Give a step a stable lineageKey describing its objective. When retrying the same objective, preserve its lineageKey;
        change it only when the objective materially changes. Rails uses this explicit identity to detect repeated attempts.
        If one specific missing source prevents a responsible decision, return outcome=needs_context, nextStep=null,
        followingSteps=[], and one contextRequest naming its source, reference, exact question, offset (null for the first window),
        and maxChars sized to the smallest useful context window for that question.
        For source=artifact, reference must be the artifact filename only, never an absolute or run-output path.
        A returned context window includes next_offset when more material exists; request that offset if the next window is needed.
        If the supplied information is sufficient but the decision requires stronger reasoning than the current #{model_tier} model tier,
        return outcome=needs_stronger_model with nextStep=null, followingSteps=[], and contextRequest=null.
        Otherwise return outcome=decision and contextRequest=null.

        #{JSON.generate(payload)}
      PROMPT
    end

    def truncate(value)
      text = value.to_s
      text.length > TEXT_LIMIT ? "#{text.first(TEXT_LIMIT).rstrip}…" : text
    end
    private_class_method :truncate
  end
end

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
          completion_blockers: AcceptanceCriteria.completion_blockers(run_id: run.run_id)
        },
        run_context: RunContext.snapshot(run_id: run.run_id),
        acceptance_criteria: AcceptanceCriteria.tree(run_id: run.run_id),
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
        Do not inspect files, update memory, or execute work. You must submit your decision by calling
        submit_planner_decision -- it is your only way to finish this turn; a text-only response is a failure.
        If it returns accepted=false, read the error, correct your proposal, and call submit_planner_decision again.
        Call it as many times as needed for outcome=needs_context (its response includes the fetched context you asked
        for); call it exactly once to finish with outcome=decision or outcome=needs_stronger_model.
        Choose at most one nextStep. Keep followingSteps ordered and limited to concrete work already justified by the evidence.
        Rails executes acceptance work depth-first: every handoff must address one root acceptance branch (a child may address its root branch), and later branches remain pending until the active branch resolves. When a verifier rejects evidence or a worker discovers follow-up work, propose the next child in that same branch; do not jump to another criterion's verifier.
        On the initial decision, define a concise top-level acceptanceCriteria contract (parentKey=null for each) derived
        directly from the user's requested outcomes. Criteria describe observable outcomes, not implementation steps. The
        top-level contract is immutable after the first decision -- never propose new parentKey=null criteria later. At any
        later decision, you may decompose an existing criterion (top-level or already-nested) into child sub-goals by
        proposing new criteria whose parentKey names that existing criterion's key; do this only when a criterion genuinely
        needs breaking down to be addressable. A criterion with children resolves only once every child resolves; its own
        status is then ignored. Every step you propose, including diagnosis, must set addressesCriteria to the real, current
        acceptance criteria keys (top-level or nested, see the acceptance_criteria tree below) it works toward -- Rails checks
        this structurally, not by parsing prose, so name exact keys. You cannot mark a criterion verified yourself -- use
        acceptanceUpdates with status=ready_for_verification and a workspace-relative evidenceRef naming the candidate
        evidence once supplied worker evidence appears to positively satisfy an existing criterion; Rails then spawns an
        independent verifier worker that re-checks the claim itself and is the only thing that can set status=verified.
        Blocked work, source edits alone, estimates, and absence of errors are not positive evidence -- do not propose
        ready_for_verification for those. Waive only when the user explicitly authorized it. Use blocked when a criterion
        is genuinely stuck rather than silently leaving it pending.
        Never return nextStep=null while completion_blockers remain that are still pending, in_progress, or blocked
        after applying justified acceptanceUpdates -- a criterion you just moved to ready_for_verification does not
        require a nextStep; Rails has already spawned an independent verifier for it.
        A diagnosis step must be source_protected. An implementation step must name exact workspace-relative file paths in
        allowedPaths. An exact file path names one file: it must not end in "/" and must not contain glob characters
        (*, ?, [, ], {, or }). Directory paths such as "front/" and patterns such as "front/**/*.ts" are invalid.
        Every nextStep or followingSteps artifact must be a filename only (for example "phone-demo-baseline.md"), never
        a path such as "artifacts/phone-demo-baseline.md"; Rails places it in the managed run artifact directory.
        Use mode=recording for running a demo or collecting recording/timing artifacts, even when owner=infrastructure;
        recording and verification must use writeScope=source_protected and allowedPaths=[]. Use mode=infrastructure only
        when the step is authorized to modify exact infrastructure files with writeScope=scoped_changes.
        When the run has a performance objective, every proposed step's successCheck must explicitly retain it. A
        verification step must require evidence that the result is faster than the baseline; merely collecting or
        comparing timings does not verify the requested improvement.
        If the task is ambiguous and no known source contains the missing detail, choose a bounded diagnosis step that locates
        the target and measures a baseline. Do not use needs_context to search the repository or repeatedly ask for absent facts.
        Treat a user question as a last resort. When worker evidence identifies an exact, non-protected workspace file and a
        bounded implementation or infrastructure change can remove the blocker, choose that scoped change first, then verify it.
        Do not ask the user merely because a prior source-protected diagnosis could not edit the identified file; a subsequent
        implementation step may authorize that exact path. Ask only when the next action needs a protected-path approval,
        an external credential/resource, or a materially open-ended product decision.
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

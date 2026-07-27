module Orchestrator
  # A dead or blocked git worker must be retried by re-requesting a fresh
  # git-role spawn, never through planner recovery: StepPolicy::PLANNER_STEP_OWNERS
  # deliberately excludes "git" (the same reason it excludes "verifier"), so a
  # planner asked to retry publication after a blocked worker_turn can only
  # dispatch a worker/infrastructure-role stand-in that has no git access at
  # all. Mirrors VerifierRecovery's shape: try the normal chaperone escalation
  # first (2+ failures on this lineage), and only requeue directly when the
  # chaperone hasn't fired yet -- so the git worker still starts small every
  # time, and a stronger model only ever gets involved because the chaperone
  # judged it necessary after a repeated failure, never by default.
  module GitPublicationRecovery
    module_function

    def applicable?(attempt)
      attempt.spawn_request&.requested_role == "git"
    end

    def call(attempt)
      ChaperoneTrigger.call(attempt) || requeue!(attempt.run)
    end

    def requeue!(run)
      RunPublication.queue_worker!(run)
      run.publish_phase!(
        phase: "planning", owner: "orchestrator",
        summary: "The git worker's previous attempt did not finish; Rails re-queued it."
      )
      :requeued
    end
  end
end

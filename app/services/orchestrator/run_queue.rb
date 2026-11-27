module Orchestrator
  # Which queued runs the dispatcher would start, and in what order: one
  # place, so RunDispatchJob claiming runs and queue_run/reopen_session
  # telling a run how many are ahead of it can never disagree.
  #
  # The queue is global, like the concurrency cap (RunConcurrency): oldest
  # first by when a run was first queued, across every workspace. A queued run
  # whose `after` dependencies are not merged (waiting or blocked,
  # RunDependencies) is passed over, holding no slot, so it never delays a run
  # queued after it. RunDispatchJob also passes over a run whose runner is at
  # its own cap (RunConcurrency); that depends on which slots are free at that
  # moment, so it is checked there and not counted here.
  module RunQueue
    module_function

    # Queued runs, oldest first, for the dispatcher to try in turn.
    def queued
      Run.where(status: "queued").order(:created_at, :id)
    end

    # Whether the dispatcher would start `run` given a slot.
    def eligible?(run)
      run.status == "queued" && RunDependencies.ready?(run)
    end

    # The queued runs the dispatcher would start before `run`: older, and
    # eligible themselves.
    def ahead_of(run)
      queued.where("created_at < ?", run.created_at).where.not(id: run.id).select { |candidate| eligible?(candidate) }
    end

    def ahead_count(run)
      ahead_of(run).size
    end
  end
end

# Starts queued runs as slots free up. This is the whole scheduler: there is
# no planner deciding what to do next, no per-run tick, and no spawn-request
# queue -- just "is there room, and is anything waiting?"
#
# Runs on a recurring schedule as a floor, and is also enqueued directly the
# moment a slot frees (Orchestrator::RunCompletion) so the next run starts
# immediately rather than waiting out the interval.
class RunDispatchJob < ApplicationJob
  queue_as :default

  # Oldest first, one pass. A run needs a slot under the global cap and under
  # its runner's own (Orchestrator::RunConcurrency): a run whose runner is full
  # is passed over, not waited on, so runs for another runner with room still
  # start. A run whose dependencies are not merged yet is passed over too: it
  # stays queued, holds no slot, and runs queued after it go first.
  def perform
    slots = Orchestrator::RunConcurrency.slots
    return unless slots.any?

    Orchestrator::RunQueue.queued.each do |candidate|
      break unless slots.any?
      next unless slots.free_on?(candidate.runner_id)
      next unless Orchestrator::RunQueue.eligible?(candidate)
      next unless claim(candidate)

      slots.take(candidate.runner_id)
      StartRunSessionJob.perform_later(candidate.id)
    end
  end

  private

  # Compare-and-set rather than a row lock: SQLite has no SELECT ... FOR
  # UPDATE, and a conditional UPDATE is atomic on every backend. If two
  # dispatchers race for the same run, exactly one sees a row count of 1.
  #
  # Orchestrator::RunCancel stops a queued run with the same compare-and-set
  # on status "queued", so a run is claimed or cancelled, never both.
  def claim(candidate)
    Run.where(id: candidate.id, status: "queued").update_all(status: "launching", updated_at: Time.current) == 1
  end
end

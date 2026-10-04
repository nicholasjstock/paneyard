# Starts queued runs as slots free up. This is the whole scheduler: there is
# no planner deciding what to do next, no per-run tick, and no spawn-request
# queue -- just "is there room, and is anything waiting?"
#
# Runs on a recurring schedule as a floor, and is also enqueued directly the
# moment a slot frees (Orchestrator::RunCompletion) so the next run starts
# immediately rather than waiting out the interval.
class RunDispatchJob < ApplicationJob
  queue_as :default

  def perform
    Orchestrator::RunConcurrency.available_slots.times do
      run = claim_next_queued_run
      break unless run

      StartRunSessionJob.perform_later(run.id)
    end
  end

  private

  # Compare-and-set rather than a row lock: SQLite has no SELECT ... FOR
  # UPDATE, and a conditional UPDATE is atomic on every backend. If two
  # dispatchers race for the same run, exactly one sees a row count of 1.
  #
  # A run whose dependencies are not merged yet is passed over, not claimed:
  # it stays queued, holds no slot, and runs queued after it go first.
  def claim_next_queued_run
    Run.where(status: "queued").order(:created_at).each do |candidate|
      next unless Orchestrator::RunDependencies.ready?(candidate)

      claimed = Run.where(id: candidate.id, status: "queued")
        .update_all(status: "launching", updated_at: Time.current)
      return candidate.reload if claimed == 1
    end
    nil
  end
end

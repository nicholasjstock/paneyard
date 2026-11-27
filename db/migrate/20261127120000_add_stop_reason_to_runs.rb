class AddStopReasonToRuns < ActiveRecord::Migration[8.1]
  def change
    # Why a run was stopped without a session to report it: today only
    # cancel_run (Orchestrator::RunCancel) on a queued run, which has no
    # session to hang a checkpoint on. Cleared when the run is reopened.
    add_column :runs, :stop_reason, :text
  end
end

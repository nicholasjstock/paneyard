class AddDependencyRunIdsToRuns < ActiveRecord::Migration[8.1]
  def change
    # queue_run's `after`: the run_ids whose work must be merged into this
    # run's base branch before it launches (Orchestrator::RunDependencies).
    add_column :runs, :dependency_run_ids, :json, default: [], null: false
  end
end

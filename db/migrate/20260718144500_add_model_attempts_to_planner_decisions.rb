class AddModelAttemptsToPlannerDecisions < ActiveRecord::Migration[8.1]
  def change
    add_column :planner_decisions, :model_attempts, :json, null: false, default: []
  end
end

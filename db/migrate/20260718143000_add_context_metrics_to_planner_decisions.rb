class AddContextMetricsToPlannerDecisions < ActiveRecord::Migration[8.1]
  def change
    add_column :planner_decisions, :model_calls, :integer, null: false, default: 0
    add_column :planner_decisions, :context_requests, :json, null: false, default: []
    add_column :planner_decisions, :context_bytes, :integer, null: false, default: 0
  end
end

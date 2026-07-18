class CreatePlannerDecisions < ActiveRecord::Migration[8.1]
  def change
    create_table :planner_decisions do |t|
      t.string :decision_id, null: false
      t.string :run_id, null: false
      t.string :spawn_request_id, null: false
      t.string :status, null: false, default: "queued"
      t.string :model
      t.json :decision
      t.text :error
      t.integer :input_tokens
      t.integer :output_tokens
      t.integer :cache_read_input_tokens
      t.decimal :total_cost_usd, precision: 12, scale: 6
      t.datetime :started_at
      t.datetime :completed_at

      t.timestamps
    end

    add_index :planner_decisions, :decision_id, unique: true
    add_index :planner_decisions, :spawn_request_id, unique: true
    add_index :planner_decisions, [ :run_id, :status ]
  end
end

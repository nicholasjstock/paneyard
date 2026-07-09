class CreateOrchestratorTicks < ActiveRecord::Migration[8.1]
  def change
    create_table :orchestrator_ticks do |t|
      t.string :run_id, null: false
      t.string :phase, null: false
      t.integer :tick_count, null: false
      t.text :last_plan_summary
      t.json :pending_spawn_keys, null: false, default: []
      t.json :following_steps, null: false, default: []
      t.text :last_stall_finding

      t.timestamps
    end
    add_index :orchestrator_ticks, [ :run_id, :tick_count ], unique: true
  end
end

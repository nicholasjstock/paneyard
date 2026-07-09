class CreateRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :runs do |t|
      t.string :run_id, null: false
      t.text :task, null: false
      t.string :target_root, null: false
      t.string :scenario
      t.string :frontend_url
      t.string :launcher_variant, null: false, default: "claude"
      t.integer :supervisor_pid
      t.string :status, null: false, default: "launching"
      t.string :launched_by
      t.datetime :started_at
      t.datetime :stopped_at
      t.string :log_path

      t.timestamps
    end
    add_index :runs, :run_id, unique: true
    add_index :runs, :status
  end
end

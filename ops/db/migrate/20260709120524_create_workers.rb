class CreateWorkers < ActiveRecord::Migration[8.1]
  def change
    create_table :workers do |t|
      t.string :worker_id, null: false
      t.string :run_id, null: false
      t.string :role, null: false
      t.string :nickname, null: false
      t.text :reason, null: false
      t.string :scope, null: false
      t.string :status, null: false, default: "running"
      t.integer :pid, null: false
      t.string :prompt_path, null: false
      t.string :log_path, null: false
      t.string :last_message_path, null: false
      t.string :env_path, null: false
      t.string :command, null: false
      t.json :args, null: false, default: []
      t.datetime :started_at, null: false
      t.datetime :stopped_at
      t.text :stop_reason

      t.timestamps
    end
    add_index :workers, :worker_id, unique: true
    add_index :workers, [ :run_id, :status ]
  end
end

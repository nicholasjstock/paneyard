class CreateRunCommands < ActiveRecord::Migration[8.1]
  def change
    create_table :run_commands do |t|
      t.string :command_id, null: false
      t.string :run_id, null: false
      t.string :requested_by_worker_id
      t.string :executable, null: false
      t.json :arguments, default: [], null: false
      t.string :working_directory, null: false
      t.json :environment, default: {}, null: false
      t.text :purpose
      t.integer :pid
      t.integer :process_group_id
      t.string :status, null: false, default: "pending"
      t.integer :exit_code
      t.integer :signal
      t.string :log_path
      t.string :exit_status_path
      t.datetime :started_at
      t.datetime :finished_at
      t.datetime :last_checked_at
      t.text :failure_message

      t.timestamps
    end

    add_index :run_commands, :command_id, unique: true
    add_index :run_commands, [ :run_id, :status ]
  end
end

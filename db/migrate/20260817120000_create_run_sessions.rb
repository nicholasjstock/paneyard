class CreateRunSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :run_sessions do |t|
      t.references :run, null: false, foreign_key: true
      t.string :driver, null: false
      t.string :model
      t.string :status, null: false, default: "starting"
      t.string :agent_status
      t.string :herdr_workspace_id
      t.string :herdr_tab_id
      t.string :herdr_pane_id
      t.integer :pid
      t.string :cli_session_id
      t.string :capability_token_digest
      t.string :prompt_path
      t.string :mcp_config_path
      t.string :outcome
      t.text :result
      t.datetime :started_at
      t.datetime :ended_at
      t.datetime :last_seen_at
      t.timestamps
    end

    # A run may accumulate several sessions over its life (a PR comment can
    # reopen a closed one), but never two live at once -- the dispatcher's
    # concurrency accounting counts live sessions, so a duplicate would
    # silently consume two slots for one run.
    add_index :run_sessions, :run_id, unique: true, where: "ended_at IS NULL",
      name: "index_run_sessions_on_one_live_session_per_run"
    add_index :run_sessions, :capability_token_digest, unique: true
    add_index :run_sessions, :status
  end
end

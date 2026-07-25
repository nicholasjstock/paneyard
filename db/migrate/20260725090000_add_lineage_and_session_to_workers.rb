class AddLineageAndSessionToWorkers < ActiveRecord::Migration[8.1]
  def change
    add_column :workers, :lineage_key, :string
    add_column :workers, :cli_session_id, :string
    add_index :workers, [ :run_id, :lineage_key, :role ]
  end
end

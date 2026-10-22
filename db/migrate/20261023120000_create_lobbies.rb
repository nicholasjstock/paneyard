class CreateLobbies < ActiveRecord::Migration[8.1]
  def change
    # A workspace's lobby: the operator's own agent session on the
    # repository's checkout, opened by Orchestrator::LobbyOpen. Not a run: it
    # holds no concurrency slot and reports nothing.
    create_table :lobbies do |t|
      t.references :workspace, null: false, foreign_key: true, index: false
      t.string :branch, null: false
      t.string :driver, null: false
      t.string :model
      t.string :herdr_workspace_id
      t.string :herdr_pane_id
      t.integer :pid
      t.datetime :closed_at
      t.timestamps
    end
    # The checkout is on one branch at a time, so a workspace has at most one
    # open lobby.
    add_index :lobbies, :workspace_id, unique: true, where: "closed_at IS NULL", name: "index_lobbies_on_one_open_per_workspace"
    add_index :lobbies, :workspace_id
  end
end

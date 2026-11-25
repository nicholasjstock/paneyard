class CreateWorkspaceCheckouts < ActiveRecord::Migration[8.1]
  def change
    # Where a workspace's repository is checked out on each runner's machine:
    # the same project lives at a different path on each. The local
    # runner's row mirrors workspaces.repository_path, which stays as the
    # local checkout for now (Workspace#repository_path_for).
    create_table :workspace_checkouts do |t|
      t.references :workspace, null: false, foreign_key: true, index: false
      t.references :runner, null: false, foreign_key: true, index: false
      t.string :repository_path, null: false
      t.timestamps
    end
    add_index :workspace_checkouts, [ :workspace_id, :runner_id ], unique: true
    add_index :workspace_checkouts, [ :runner_id, :repository_path ], unique: true

    reversible do |direction|
      direction.up do
        execute <<~SQL
          INSERT INTO workspace_checkouts (workspace_id, runner_id, repository_path, created_at, updated_at)
          SELECT workspaces.id, runners.id, workspaces.repository_path, workspaces.created_at, workspaces.updated_at
          FROM workspaces, runners WHERE runners.kind = 'local'
        SQL
      end
    end
  end
end

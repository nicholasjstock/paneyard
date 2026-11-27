class MakeWorkspacesANameAndAnOrigin < ActiveRecord::Migration[8.1]
  # A workspace stops being "the local checkout": it is a name and an origin,
  # and each runner, local included, has an optional checkout of it in
  # workspace_checkouts (Orchestrator::WorkspaceCheckout clones one on a
  # runner that needs it). So:
  #
  #   - every workspace keeps its local checkout as a workspace_checkouts row
  #     (CreateWorkspaceCheckouts made one for every workspace then; one
  #     registered since was mirrored there by Workspace), and
  #     workspaces.repository_path goes;
  #   - workspaces.origin_url is the repository a runner without a checkout
  #     clones; nil until it is first needed, when it is read from an
  #     existing checkout;
  #   - runners.projects_dir is where a runner clones (and create_workspace
  #     puts new projects): sent by a remote runner when it registers, and for
  #     the local runner PANEYARD_PROJECTS_DIR, else this column, else
  #     ~/Source. The projects_dir setting it replaces becomes the local
  #     runner's column.
  def up
    add_column :workspaces, :origin_url, :string
    add_column :runners, :projects_dir, :string

    execute <<~SQL
      INSERT INTO workspace_checkouts (workspace_id, runner_id, repository_path, created_at, updated_at)
      SELECT workspaces.id, runners.id, workspaces.repository_path, workspaces.created_at, workspaces.updated_at
      FROM workspaces, runners
      WHERE runners.kind = 'local' AND workspaces.repository_path IS NOT NULL AND workspaces.repository_path != ''
        AND NOT EXISTS (SELECT 1 FROM workspace_checkouts existing
                        WHERE existing.workspace_id = workspaces.id AND existing.runner_id = runners.id)
    SQL
    execute <<~SQL
      UPDATE runners SET projects_dir = (SELECT value FROM settings WHERE key = 'projects_dir')
      WHERE kind = 'local' AND EXISTS (SELECT 1 FROM settings WHERE key = 'projects_dir' AND value IS NOT NULL AND value != '')
    SQL
    execute "DELETE FROM settings WHERE key = 'projects_dir'"

    remove_index :workspaces, :repository_path
    remove_column :workspaces, :repository_path
  end

  # Back to a required workspaces.repository_path, the local checkout. A
  # workspace with no local checkout (registered on a remote runner only)
  # cannot be represented there and is refused rather than dropped.
  def down
    orphans = select_values(<<~SQL)
      SELECT workspaces.name FROM workspaces
      WHERE NOT EXISTS (SELECT 1 FROM workspace_checkouts, runners
                        WHERE workspace_checkouts.workspace_id = workspaces.id
                          AND workspace_checkouts.runner_id = runners.id AND runners.kind = 'local')
    SQL
    if orphans.any?
      raise ActiveRecord::IrreversibleMigration, "workspaces with no local checkout: #{orphans.join(', ')}"
    end

    add_column :workspaces, :repository_path, :string
    execute <<~SQL
      UPDATE workspaces SET repository_path = (
        SELECT workspace_checkouts.repository_path FROM workspace_checkouts, runners
        WHERE workspace_checkouts.workspace_id = workspaces.id
          AND workspace_checkouts.runner_id = runners.id AND runners.kind = 'local')
    SQL
    change_column_null :workspaces, :repository_path, false
    add_index :workspaces, :repository_path, unique: true

    now = connection.quote(Time.now.utc)
    execute <<~SQL
      INSERT INTO settings (key, value, created_at, updated_at)
      SELECT 'projects_dir', projects_dir, #{now}, #{now} FROM runners
      WHERE kind = 'local' AND projects_dir IS NOT NULL AND projects_dir != ''
    SQL
    remove_column :runners, :projects_dir
    remove_column :workspaces, :origin_url
  end
end

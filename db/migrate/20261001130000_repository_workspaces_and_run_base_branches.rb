class RepositoryWorkspacesAndRunBaseBranches < ActiveRecord::Migration[8.1]
  # A workspace used to be a directory holding a `main` checkout, with every
  # run branching from main. Now it is a repository checkout anywhere, with a
  # default base branch, and each run records the branch it started from (and
  # merges back into). Existing workspaces keep working unchanged: their
  # repository is the old <root>/main and their default branch main, and every
  # existing run started from main.
  #
  # Session env is gone (runs no longer get an environment injected into their
  # panes), so the env fixes recorded for it go too.
  def up
    add_column :workspaces, :repository_path, :string
    add_column :workspaces, :default_base_branch, :string, null: false, default: "main"
    # root_path was once saved as typed, so `~/...` may be stored.
    select_rows("SELECT id, root_path FROM workspaces").each do |id, root_path|
      repository_path = File.join(File.expand_path(root_path), "main")
      execute("UPDATE workspaces SET repository_path = #{quote(repository_path)} WHERE id = #{Integer(id)}")
    end
    change_column_null :workspaces, :repository_path, false
    add_index :workspaces, :repository_path, unique: true
    remove_index :workspaces, :root_path
    remove_column :workspaces, :root_path

    add_column :runs, :base_branch, :string
    execute("UPDATE runs SET base_branch = 'main'")
    change_column_null :runs, :base_branch, false

    drop_table :workspace_env_vars
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end

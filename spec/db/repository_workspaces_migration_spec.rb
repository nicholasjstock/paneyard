require "rails_helper"
require Rails.root.join("db/migrate/20261001130000_repository_workspaces_and_run_base_branches")

# Existing installations keep working without recreating anything: a workspace
# registered as <root> (holding <root>/main) becomes that repository with main
# as its default branch, and every existing run started from main. Run against
# the old schema in a throwaway database, never the test one.
RSpec.describe RepositoryWorkspacesAndRunBaseBranches do
  let(:connection_class) do
    Class.new(ActiveRecord::Base) do
      self.abstract_class = true
      def self.name = "MigrationSpecRecord"
    end
  end

  before do
    connection_class.establish_connection(adapter: "sqlite3", database: ":memory:")
    db = connection_class.connection
    db.create_table(:workspaces) do |t|
      t.string :name, null: false
      t.string :root_path, null: false
      t.text :layout
      t.timestamps
    end
    db.add_index :workspaces, :root_path, unique: true
    db.create_table(:runs) do |t|
      t.integer :workspace_id
      t.string :run_id
      t.string :target_root
    end
    db.create_table(:workspace_env_vars) do |t|
      t.integer :workspace_id
      t.string :name
    end
    db.execute("INSERT INTO workspaces (name, root_path, created_at, updated_at) VALUES ('app', '/code/app', '2026-01-01', '2026-01-01')")
    db.execute("INSERT INTO workspaces (name, root_path, created_at, updated_at) VALUES ('typed', '~/src/typed', '2026-01-01', '2026-01-01')")
    db.execute("INSERT INTO runs (workspace_id, run_id, target_root) VALUES (1, 'run-old', '/code/app/fix-1')")
  end

  after { connection_class.remove_connection }

  it "turns <root>/main workspaces into repositories on main, and starts every existing run from main" do
    db = connection_class.connection
    ActiveRecord::Migration.suppress_messages { described_class.new.exec_migration(db, :up) }

    expect(db.select_rows("SELECT name, repository_path, default_base_branch FROM workspaces ORDER BY id")).to eq([
      [ "app", "/code/app/main", "main" ],
      [ "typed", File.join(File.expand_path("~/src/typed"), "main"), "main" ]
    ])
    expect(db.column_exists?(:workspaces, :root_path)).to be(false)
    expect(db.index_exists?(:workspaces, :repository_path, unique: true)).to be(true)
    expect(db.select_rows("SELECT run_id, base_branch, target_root FROM runs")).to eq([ [ "run-old", "main", "/code/app/fix-1" ] ])
    expect(db.columns(:runs).find { |column| column.name == "base_branch" }.null).to be(false)
    expect(db.table_exists?(:workspace_env_vars)).to be(false)
  end
end

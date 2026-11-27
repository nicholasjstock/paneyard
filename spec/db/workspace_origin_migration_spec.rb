require "rails_helper"
require Rails.root.join("db/migrate/20261127100000_make_workspaces_a_name_and_an_origin")

# An existing installation's workspaces keep their local checkouts, as
# workspace_checkouts rows, once workspaces.repository_path goes; its
# projects_dir setting becomes the local runner's. Run against the old
# schema in a throwaway database, never the test one.
RSpec.describe "the workspaces-are-a-name-and-an-origin migration" do
  let(:connection_class) do
    Class.new(ActiveRecord::Base) do
      self.abstract_class = true
      def self.name = "WorkspaceOriginMigrationSpecRecord"
    end
  end
  let(:db) { connection_class.connection }

  before do
    connection_class.establish_connection(adapter: "sqlite3", database: ":memory:")
    db.create_table(:workspaces) do |t|
      t.string :name, null: false
      t.string :repository_path, null: false
      t.string :default_base_branch, null: false, default: "main"
      t.timestamps
    end
    db.add_index :workspaces, :repository_path, unique: true
    db.create_table(:runners) do |t|
      t.string :name, null: false
      t.string :kind, null: false
      t.string :url
      t.timestamps
    end
    db.create_table(:workspace_checkouts) do |t|
      t.references :workspace, null: false, foreign_key: true, index: false
      t.references :runner, null: false, foreign_key: true, index: false
      t.string :repository_path, null: false
      t.timestamps
    end
    db.create_table(:settings) do |t|
      t.string :key, null: false
      t.string :value
      t.timestamps
    end
    now = "'2026-01-01'"
    db.execute("INSERT INTO runners (name, kind, created_at, updated_at) VALUES ('local', 'local', #{now}, #{now})")
    db.execute("INSERT INTO runners (name, kind, url, created_at, updated_at) VALUES ('mac', 'remote', 'http://mac', #{now}, #{now})")
    # app was mirrored into workspace_checkouts already; lib was not; both
    # are on mac too.
    db.execute("INSERT INTO workspaces (name, repository_path, created_at, updated_at) VALUES ('app', '/code/app', #{now}, #{now})")
    db.execute("INSERT INTO workspaces (name, repository_path, created_at, updated_at) VALUES ('lib', '/code/lib', #{now}, #{now})")
    db.execute("INSERT INTO workspace_checkouts (workspace_id, runner_id, repository_path, created_at, updated_at) VALUES " \
      "(1, 1, '/code/app', #{now}, #{now}), (1, 2, '/Users/me/app', #{now}, #{now}), (2, 2, '/Users/me/lib', #{now}, #{now})")
    db.execute("INSERT INTO settings (key, value, created_at, updated_at) VALUES ('projects_dir', '/code', #{now}, #{now}), " \
      "('default_github_owner', 'Gembani', #{now}, #{now})")
  end

  after { connection_class.remove_connection }

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { MakeWorkspacesANameAndAnOrigin.new.exec_migration(db, direction) }
  end

  def checkouts
    db.select_rows("SELECT workspace_id, runner_id, repository_path FROM workspace_checkouts ORDER BY workspace_id, runner_id")
  end

  it "records every workspace's local checkout, drops repository_path, and moves projects_dir onto the local runner" do
    migrate(:up)

    expect(checkouts).to eq([ [ 1, 1, "/code/app" ], [ 1, 2, "/Users/me/app" ], [ 2, 1, "/code/lib" ], [ 2, 2, "/Users/me/lib" ] ])
    expect(db.column_exists?(:workspaces, :repository_path)).to be(false)
    expect(db.column_exists?(:workspaces, :origin_url)).to be(true)
    expect(db.select_rows("SELECT name, projects_dir FROM runners ORDER BY id")).to eq([ [ "local", "/code" ], [ "mac", nil ] ])
    expect(db.select_rows("SELECT key, value FROM settings")).to eq([ [ "default_github_owner", "Gembani" ] ])
  end

  it "rolls back to the old schema" do
    migrate(:up)
    migrate(:down)

    expect(db.select_rows("SELECT name, repository_path FROM workspaces ORDER BY id")).to eq([ [ "app", "/code/app" ], [ "lib", "/code/lib" ] ])
    expect(db.columns(:workspaces).find { |column| column.name == "repository_path" }.null).to be(false)
    expect(db.column_exists?(:runners, :projects_dir)).to be(false)
    expect(db.select_rows("SELECT key, value FROM settings ORDER BY key")).to eq([ [ "default_github_owner", "Gembani" ], [ "projects_dir", "/code" ] ])
  end

  it "will not roll back over a workspace with no local checkout" do
    migrate(:up)
    db.execute("INSERT INTO workspaces (name, default_base_branch, created_at, updated_at) VALUES ('remote-only', 'main', '2026-01-02', '2026-01-02')")

    expect { migrate(:down) }.to raise_error(ActiveRecord::IrreversibleMigration, /remote-only/)
  end
end

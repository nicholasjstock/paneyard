require "rails_helper"
require Rails.root.join("db/migrate/20261125180000_create_runners")
require Rails.root.join("db/migrate/20261125180100_add_runner_to_runs")
require Rails.root.join("db/migrate/20261125180200_create_workspace_checkouts")

# An existing installation gets the runner registry with nothing to do: one
# local runner, every existing run on it, and every workspace's repository
# recorded as its checkout there. Run against the old schema in a throwaway
# database, never the test one.
RSpec.describe "the runner registry migrations" do
  let(:connection_class) do
    Class.new(ActiveRecord::Base) do
      self.abstract_class = true
      def self.name = "RunnerMigrationSpecRecord"
    end
  end
  let(:migrations) { [ CreateRunners, AddRunnerToRuns, CreateWorkspaceCheckouts ] }
  let(:db) { connection_class.connection }

  before do
    connection_class.establish_connection(adapter: "sqlite3", database: ":memory:")
    db.create_table(:workspaces) do |t|
      t.string :name, null: false
      t.string :repository_path, null: false
      t.timestamps
    end
    db.create_table(:runs) do |t|
      t.references :workspace, null: false, foreign_key: true
      t.string :run_id, null: false
    end
    db.execute("INSERT INTO workspaces (name, repository_path, created_at, updated_at) VALUES ('app', '/code/app', '2026-01-01', '2026-01-02')")
    db.execute("INSERT INTO workspaces (name, repository_path, created_at, updated_at) VALUES ('lib', '/code/lib', '2026-01-01', '2026-01-01')")
    db.execute("INSERT INTO runs (workspace_id, run_id) VALUES (1, 'run-a'), (2, 'run-b')")
  end

  after { connection_class.remove_connection }

  def migrate(direction, list = migrations)
    ActiveRecord::Migration.suppress_messages { list.each { |migration| migration.new.exec_migration(db, direction) } }
  end

  it "adds the local runner, puts every run on it, and records each workspace's checkout there" do
    migrate(:up)

    expect(db.select_rows("SELECT id, name, kind, url, max_concurrent_runs FROM runners")).to eq([ [ 1, "local", "local", nil, nil ] ])
    expect(db.select_rows("SELECT run_id, runner_id FROM runs ORDER BY id")).to eq([ [ "run-a", 1 ], [ "run-b", 1 ] ])
    expect(db.columns(:runs).find { |column| column.name == "runner_id" }.null).to be(false)
    expect(db.foreign_keys(:runs).map(&:to_table)).to include("runners", "workspaces")
    expect(db.select_rows("SELECT workspace_id, runner_id, repository_path FROM workspace_checkouts ORDER BY workspace_id"))
      .to eq([ [ 1, 1, "/code/app" ], [ 2, 1, "/code/lib" ] ])
    expect(db.index_exists?(:workspace_checkouts, [ :workspace_id, :runner_id ], unique: true)).to be(true)
  end

  it "allows one local runner only" do
    migrate(:up)

    expect { db.execute("INSERT INTO runners (name, kind, created_at, updated_at) VALUES ('other', 'local', '2026-01-01', '2026-01-01')") }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "rolls back to the old schema" do
    migrate(:up)
    migrate(:down, migrations.reverse)

    expect(db.table_exists?(:runners)).to be(false)
    expect(db.table_exists?(:workspace_checkouts)).to be(false)
    expect(db.column_exists?(:runs, :runner_id)).to be(false)
    expect(db.select_values("SELECT run_id FROM runs ORDER BY id")).to eq(%w[run-a run-b])
  end
end

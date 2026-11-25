class CreateRunners < ActiveRecord::Migration[8.1]
  def change
    # The runner registry (docs/multi-runner-plan.md): the machines runs
    # happen on. The local runner, in this process, is always there
    # (RegisteredRunner.local); a remote one is another machine's runner-only
    # process, reached at its url over the tailnet (not implemented yet).
    create_table :runners do |t|
      t.string :name, null: false
      t.string :kind, null: false
      t.string :url
      # Nil: only the global cap (Orchestrator::RunConcurrency) applies.
      t.integer :max_concurrent_runs
      t.timestamps
    end
    add_index :runners, :name, unique: true
    # There is one local runner: this process.
    add_index :runners, :kind, unique: true, where: "kind = 'local'", name: "index_runners_on_one_local"

    reversible do |direction|
      direction.up do
        now = connection.quote(Time.now.utc)
        execute "INSERT INTO runners (name, kind, created_at, updated_at) VALUES ('local', 'local', #{now}, #{now})"
      end
    end
  end
end

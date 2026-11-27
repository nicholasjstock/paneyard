class CreateRunMoves < ActiveRecord::Migration[8.1]
  def change
    # One row per time a run moved from one runner to another
    # (Orchestrator::RunMove): the run's history of where it happened, what
    # crossed, and the worktree it left behind on the runner it left, which
    # WorktreeJanitor keeps sweeping there under its usual rules until its
    # work is saved.
    create_table :run_moves do |t|
      t.references :run, null: false, foreign_key: true
      t.references :from_runner, null: false, foreign_key: { to_table: :runners }
      t.references :to_runner, null: false, foreign_key: { to_table: :runners }
      # The run's worktree and repository on from_runner when it left.
      t.string :source_repository_path, null: false
      t.string :source_target_root
      # none (it had no worktree there by then), kept, removed, reused (the
      # run came back and took it again), or error.
      t.string :source_worktree, null: false, default: "none"
      t.text :source_worktree_error
      # The worktree it got on to_runner.
      t.string :target_root, null: false
      # What crossed: head, commits, files, transcripts.
      t.json :transferred, null: false, default: {}
      t.timestamps
    end
  end
end

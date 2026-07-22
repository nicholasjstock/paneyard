class AddWorktreePublicationToRuns < ActiveRecord::Migration[8.1]
  def change
    change_table :runs, bulk: true do |t|
      t.string :worktree_name
      t.string :source_root
      t.string :branch_name
      t.string :base_sha
      t.string :publication_status
      t.string :pull_request_url
      t.text :publication_error
      t.datetime :publication_started_at
      t.datetime :publication_completed_at
    end
    add_index :runs, :worktree_name
    add_index :runs, :publication_status
  end
end

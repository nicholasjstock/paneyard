# Rails no longer opens, updates, watches, or cleans up after pull requests.
# A session pushes its own branch; what happens to it on GitHub is the
# operator's business. The one publication column still meaningful is the
# error, which StartRunSessionJob has always used for launch failures too.
class RemovePullRequestPublication < ActiveRecord::Migration[8.1]
  def change
    rename_column :runs, :publication_error, :launch_error

    remove_index :runs, :publication_status, name: "index_runs_on_publication_status"
    remove_column :runs, :publication_status, :string
    remove_column :runs, :publication_started_at, :datetime
    remove_column :runs, :publication_completed_at, :datetime
    remove_column :runs, :pull_request_url, :string
    remove_column :runs, :last_pull_request_comment_id, :string

    drop_table :run_outbound_comments do |t|
      t.string :run_id, null: false
      t.string :github_comment_id, null: false
      t.string :kind, null: false
      t.timestamps
      t.index %i[run_id github_comment_id], unique: true
    end
  end
end

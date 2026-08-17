class AddLastPullRequestCommentIdToRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :runs, :last_pull_request_comment_id, :string
  end
end

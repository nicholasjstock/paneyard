class AddGitHubIssueToRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :runs, :github_issue_url, :string
    add_column :runs, :github_issue_status, :string
  end
end

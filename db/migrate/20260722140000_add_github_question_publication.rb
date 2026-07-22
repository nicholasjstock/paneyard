class AddGithubQuestionPublication < ActiveRecord::Migration[8.1]
  def change
    add_column :runs, :conversation_pr_status, :string
    add_column :user_questions, :github_comment_id, :string
    add_column :user_questions, :github_comment_url, :string
    add_column :user_questions, :github_published_at, :datetime
    add_column :user_questions, :github_publication_error, :text

    add_index :runs, :conversation_pr_status
    add_index :user_questions, :github_comment_id, unique: true
  end
end

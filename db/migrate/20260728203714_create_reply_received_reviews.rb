class CreateReplyReceivedReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :reply_received_reviews do |t|
      t.string :review_id, null: false
      t.string :run_id, null: false
      t.string :user_question_id, null: false
      t.string :github_comment_id, null: false
      t.string :github_comment_author
      t.text :github_comment_body
      t.string :status, null: false, default: "queued"
      t.string :token_digest, null: false
      t.string :action
      t.text :summary
      t.text :explanation
      t.json :tool_calls, null: false, default: []
      t.datetime :expires_at, null: false
      t.datetime :completed_at
      t.timestamps
    end

    add_index :reply_received_reviews, :review_id, unique: true
    add_index :reply_received_reviews, :token_digest, unique: true
    add_index :reply_received_reviews, [ :run_id, :status ]
  end
end

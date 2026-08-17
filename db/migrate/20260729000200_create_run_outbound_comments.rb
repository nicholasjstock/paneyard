class CreateRunOutboundComments < ActiveRecord::Migration[8.1]
  def change
    create_table :run_outbound_comments do |t|
      t.string :run_id, null: false
      t.string :github_comment_id, null: false
      t.string :kind, null: false
      t.timestamps
    end

    add_index :run_outbound_comments, [ :run_id, :github_comment_id ], unique: true
  end
end

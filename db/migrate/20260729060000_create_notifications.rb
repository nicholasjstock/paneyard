class CreateNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :notifications do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :user_question, null: false, foreign_key: true, index: { unique: true }
      t.string :kind, null: false
      t.string :title, null: false
      t.text :body, null: false
      t.string :link_url
      t.datetime :read_at
      t.timestamps
    end

    add_index :notifications, [ :workspace_id, :read_at ]
  end
end

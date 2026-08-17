class CreateWorkspaceChats < ActiveRecord::Migration[8.1]
  def change
    create_table :workspace_chats do |t|
      t.references :workspace, null: false, foreign_key: true, index: { unique: true }
      t.string :title, null: false, default: "New conversation"
      t.string :session_id
      t.string :status, null: false, default: "idle"
      t.text :last_error
      t.timestamps
    end

    create_table :workspace_chat_messages do |t|
      t.references :workspace_chat, null: false, foreign_key: true
      t.string :role, null: false
      t.text :content, null: false
      t.string :status, null: false, default: "completed"
      t.json :usage, null: false, default: {}
      t.timestamps
    end
  end
end

class CreateWorkspaceAdminChatMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :workspace_admin_chat_messages do |t|
      t.references :workspace_admin_chat, null: false, foreign_key: true
      t.string :role, null: false
      t.string :provider
      t.string :turn_id
      t.string :status, null: false, default: "queued"
      t.text :content, default: "", null: false
      t.json :events, default: [], null: false
      t.json :usage, default: {}, null: false
      t.text :error_message

      t.timestamps
    end

    add_index :workspace_admin_chat_messages, :turn_id
  end
end

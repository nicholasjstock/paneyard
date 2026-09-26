# The admin chat gets its own MCP capability so it can inspect and steer this
# workspace's runs. Long-lived rather than per-turn: the chat itself is the
# durable subject, and a turn is just one invocation of it.
class AddCapabilityToWorkspaceAdminChats < ActiveRecord::Migration[8.1]
  def change
    add_column :workspace_admin_chats, :capability_token_digest, :string
    add_index :workspace_admin_chats, :capability_token_digest, unique: true
  end
end

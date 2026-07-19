class AddWorkerCapabilitiesAndExecutionPolicy < ActiveRecord::Migration[8.1]
  def change
    add_column :spawn_requests, :execution_mode, :string
    add_column :spawn_requests, :write_scope, :string
    add_column :spawn_requests, :allowed_paths, :json, default: [], null: false
    add_column :spawn_requests, :evidence_refs, :json, default: [], null: false

    add_column :workers, :capability_token_digest, :string
    add_column :workers, :execution_mode, :string
    add_column :workers, :write_scope, :string
    add_column :workers, :allowed_paths, :json, default: [], null: false
    add_column :workers, :mcp_config_path, :string
    add_index :workers, :capability_token_digest, unique: true
  end
end

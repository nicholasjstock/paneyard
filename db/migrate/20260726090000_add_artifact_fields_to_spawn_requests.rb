class AddArtifactFieldsToSpawnRequests < ActiveRecord::Migration[7.1]
  def change
    add_column :spawn_requests, :required_artifacts, :json, default: [], null: false
    add_column :spawn_requests, :inherited_artifacts, :json, default: [], null: false
    add_column :spawn_requests, :artifact_inheritance_chain, :json, default: [], null: false
  end
end

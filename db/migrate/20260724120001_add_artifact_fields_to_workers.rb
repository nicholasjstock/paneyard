class AddArtifactFieldsToWorkers < ActiveRecord::Migration[7.1]
  def change
    add_column :workers, :inherited_artifacts, :json, default: [], null: false
    add_column :workers, :produced_artifacts, :json, default: [], null: false
  end
end

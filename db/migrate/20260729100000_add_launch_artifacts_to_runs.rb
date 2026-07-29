class AddLaunchArtifactsToRuns < ActiveRecord::Migration[8.1]
  def change
    add_reference :runs, :parent_run, foreign_key: { to_table: :runs }
    add_column :runs, :launch_artifacts, :json, default: [], null: false
  end
end

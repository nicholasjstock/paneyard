class AddWorkingRootToSpawnRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :spawn_requests, :working_root, :string
  end
end

class CreateGitChangeRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :git_change_requests do |t|
      t.string :run_id, null: false
      t.string :requested_by_worker_id, null: false
      t.string :path, null: false
      t.text :reason, null: false
      t.string :status, null: false, default: "requested"

      t.timestamps
    end
    add_index :git_change_requests, :run_id
    add_index :git_change_requests, [ :run_id, :path ], unique: true
  end
end

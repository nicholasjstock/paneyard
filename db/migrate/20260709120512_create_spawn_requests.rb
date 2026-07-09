class CreateSpawnRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :spawn_requests do |t|
      t.string :request_id, null: false
      t.string :run_id, null: false
      t.string :asked_by, null: false
      t.datetime :asked_at, null: false
      t.string :scope, null: false
      t.text :text, null: false
      t.text :context
      t.string :requested_role, null: false
      t.string :priority, null: false, default: "advisory"
      t.string :status, null: false, default: "open"
      t.string :fulfilled_by
      t.datetime :fulfilled_at
      t.text :fulfillment_note
      t.string :fulfilled_worker_id
      t.string :dismissed_by
      t.datetime :dismissed_at
      t.text :dismissal_note
      t.json :tags, null: false, default: []

      t.timestamps
    end
    add_index :spawn_requests, :request_id, unique: true
    add_index :spawn_requests, [ :run_id, :status ]
  end
end

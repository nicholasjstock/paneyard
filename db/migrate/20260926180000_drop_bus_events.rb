# The event bus fed an activity feed and a per-run timeline that only ever
# restated state already held elsewhere: run status/stopped_at, the
# RunCheckpoint history, and the admin chat transcript. Models broadcast
# their own Turbo refreshes, so nothing depends on it any more.
class DropBusEvents < ActiveRecord::Migration[8.1]
  def change
    drop_table :bus_events do |t|
      t.string :event_id, null: false
      t.string :event_type, null: false
      t.string :run_id
      t.json :payload, null: false, default: {}
      t.timestamps
      t.index :event_id, unique: true
      t.index :run_id
    end
  end
end

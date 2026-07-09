class CreateBusEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :bus_events do |t|
      t.string :event_id, null: false
      # Rails reserves the bare column name "type" for single-table
      # inheritance -- using it here would make ActiveRecord try to treat
      # each event's type string (e.g. "worker.spawned") as a subclass name.
      t.string :event_type, null: false
      t.string :run_id
      t.json :payload, null: false, default: {}

      t.timestamps
    end
    add_index :bus_events, :event_id, unique: true
    add_index :bus_events, :run_id
  end
end

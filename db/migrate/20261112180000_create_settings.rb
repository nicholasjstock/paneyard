class CreateSettings < ActiveRecord::Migration[8.1]
  def change
    # Operator settings kept in the database rather than the environment, so
    # they are set over /mcp/admin (update_settings) and apply without a
    # restart: one row per key (Setting::KEYS).
    create_table :settings do |t|
      t.string :key, null: false
      t.string :value
      t.timestamps
    end
    add_index :settings, :key, unique: true
  end
end

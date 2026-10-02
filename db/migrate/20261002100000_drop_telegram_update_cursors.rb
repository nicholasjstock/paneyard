class DropTelegramUpdateCursors < ActiveRecord::Migration[8.1]
  def change
    drop_table :telegram_update_cursors do |t|
      t.string :name, null: false
      t.integer :last_update_id, null: false, default: -1
      t.timestamps

      t.index :name, unique: true
    end
  end
end

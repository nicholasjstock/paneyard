class CreateTelegramUpdateCursors < ActiveRecord::Migration[8.1]
  def change
    create_table :telegram_update_cursors do |t|
      t.string :name, null: false
      t.integer :last_update_id, null: false, default: -1

      t.timestamps
    end

    add_index :telegram_update_cursors, :name, unique: true
  end
end

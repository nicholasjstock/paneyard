class AddCapacityAvailableAtToRuns < ActiveRecord::Migration[8.0]
  def change
    add_column :runs, :capacity_available_at, :datetime
    add_index :runs, :capacity_available_at
  end
end

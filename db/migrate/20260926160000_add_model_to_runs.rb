class AddModelToRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :runs, :model, :string
  end
end

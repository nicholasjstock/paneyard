class AddLogUpdatedAtToWorkers < ActiveRecord::Migration[8.1]
  def change
    add_column :workers, :log_updated_at, :datetime
  end
end

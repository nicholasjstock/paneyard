class AddClickPathToWorkers < ActiveRecord::Migration[8.1]
  def change
    add_column :workers, :click_path, :text
  end
end

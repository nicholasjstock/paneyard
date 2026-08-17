class AddExitObservabilityToWorkers < ActiveRecord::Migration[8.1]
  def change
    add_column :workers, :exit_status_path, :string
    add_column :workers, :exit_code, :integer
  end
end

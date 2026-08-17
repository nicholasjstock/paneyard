class AddActiveBranchKeyToRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :runs, :active_branch_key, :string
    add_index :runs, :active_branch_key
  end
end

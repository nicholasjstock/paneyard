class AddWorkspaceToRuns < ActiveRecord::Migration[8.1]
  def change
    add_reference :runs, :workspace, null: true, foreign_key: true
  end
end

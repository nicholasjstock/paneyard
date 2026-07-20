class AddCliOutputToPlannerDecisions < ActiveRecord::Migration[8.1]
  def change
    add_column :planner_decisions, :cli_output, :text
  end
end

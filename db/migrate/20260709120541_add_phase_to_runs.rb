class AddPhaseToRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :runs, :phase, :string
    add_column :runs, :phase_owner, :string
    add_column :runs, :phase_summary, :text
    add_column :runs, :phase_updated_at, :datetime
  end
end

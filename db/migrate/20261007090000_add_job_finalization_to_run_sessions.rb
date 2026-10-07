class AddJobFinalizationToRunSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :run_sessions, :finalization_requested_at, :datetime
    add_column :run_sessions, :finalization_ready_at, :datetime
    add_column :run_sessions, :finalization_completed_at, :datetime
    add_column :run_sessions, :finalization_error, :text
  end
end

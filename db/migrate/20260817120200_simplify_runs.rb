# Strips the runs table down to what a queued job actually needs.
#
# Three concepts leave with the planner: the free-text `phase` mirror (a run
# has one status now), the capacity/launcher-switch machinery (which existed
# because a headless worker's provider error was only visible in its
# stream-json log), and cross-run artifact inheritance via parent_run_id.
# The GitHub issue columns go with the question protocol -- an issue existed
# only to host blocking questions before a PR did.
class SimplifyRuns < ActiveRecord::Migration[8.1]
  def up
    # Nothing survives the cut mid-flight: an in-flight run's state lived
    # entirely in tables this migration's predecessor just dropped.
    execute "UPDATE runs SET status = 'stopped', stopped_at = COALESCE(stopped_at, CURRENT_TIMESTAMP) " \
      "WHERE status IN ('launching', 'running', 'stopping')"

    remove_column :runs, :active_branch_key, :string
    remove_column :runs, :phase, :string
    remove_column :runs, :phase_owner, :string
    remove_column :runs, :phase_summary, :text
    remove_column :runs, :phase_updated_at, :datetime
    remove_column :runs, :supervisor_pid, :integer
    remove_column :runs, :capacity_available_at, :datetime
    remove_column :runs, :interactive_mode, :boolean
    remove_column :runs, :log_path, :string
    remove_foreign_key :runs, column: :parent_run_id if foreign_key_exists?(:runs, column: :parent_run_id)
    remove_column :runs, :parent_run_id, :integer
    remove_column :runs, :github_issue_url, :string
    remove_column :runs, :github_issue_status, :string
    remove_column :runs, :conversation_pr_status, :string

    change_column_default :runs, :status, from: "launching", to: "queued"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end

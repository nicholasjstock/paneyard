class RequireWorkspaceOnRuns < ActiveRecord::Migration[8.1]
  def up
    default_workspace_id = select_value("SELECT id FROM workspaces ORDER BY created_at ASC LIMIT 1")
    null_run_count = select_value("SELECT COUNT(*) FROM runs WHERE workspace_id IS NULL").to_i
    if default_workspace_id.blank? && null_run_count.positive?
      raise "At least one workspace must exist before requiring workspace-scoped runs"
    end

    if default_workspace_id.present?
      execute <<~SQL.squish
        UPDATE runs
        SET workspace_id = #{connection.quote(default_workspace_id)}
        WHERE workspace_id IS NULL
      SQL
    end

    change_column_null :runs, :workspace_id, false
  end

  def down
    change_column_null :runs, :workspace_id, true
  end
end

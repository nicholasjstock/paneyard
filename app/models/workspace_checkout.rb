# Where a workspace's repository is checked out on one runner's machine. The
# same project is at a different path on each machine, so the path is per
# (workspace, runner). The local runner's row mirrors
# workspaces.repository_path, which Workspace keeps in step with it; resolve
# a path through Workspace#repository_path_for or Run#repository_path rather
# than reading either column.
class WorkspaceCheckout < ApplicationRecord
  belongs_to :workspace
  belongs_to :runner, class_name: "RegisteredRunner", inverse_of: :workspace_checkouts

  validates :repository_path, presence: true
  validates :runner_id, uniqueness: { scope: :workspace_id }
end

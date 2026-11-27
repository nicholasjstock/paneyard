# Where a workspace's repository is checked out on one runner's machine. The
# same project is at a different path on each machine, so the path is per
# (workspace, runner), and every runner is alike: the local one's row is no
# different from a remote one's. A runner without a row has no checkout yet;
# Orchestrator::WorkspaceCheckout.ensure! clones one and records it. Resolve
# a path through Workspace#repository_path_for or Run#repository_path.
class WorkspaceCheckout < ApplicationRecord
  belongs_to :workspace
  belongs_to :runner, class_name: "RegisteredRunner", inverse_of: :workspace_checkouts

  validates :repository_path, presence: true
  validates :runner_id, uniqueness: { scope: :workspace_id }
  validate :repository_path_is_unique_on_the_runner
  validate :repository_is_not_changed_while_runs_are_active
  validate :repository_path_is_inside_the_sandbox

  private

  def repository_path_is_unique_on_the_runner
    return if repository_path.blank? || runner_id.nil?

    taken = self.class.where(runner_id:, repository_path:).where.not(id:).includes(:workspace).first
    errors.add(:repository_path, "is already workspace #{taken.workspace.name.inspect}'s checkout") if taken
  end

  def repository_is_not_changed_while_runs_are_active
    return unless persisted? && will_save_change_to_repository_path?
    return unless workspace.runs.active.where(runner_id:).exists?

    errors.add(:repository_path, "cannot change while a run is active")
  end

  # A sandbox instance (Orchestrator::Sandbox) only manages scratch repos of
  # its own, so it can never be pointed at a real project's worktrees.
  def repository_path_is_inside_the_sandbox
    return if repository_path.blank? || Orchestrator::Sandbox.allows_path?(repository_path)

    errors.add(:repository_path, "must be inside the sandbox root #{Orchestrator::Sandbox.root}")
  end
end

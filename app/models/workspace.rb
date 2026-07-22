# A registered target project the orchestrator can be pointed at (e.g.
# simple-retail-planner). Runs launched from the ops UI pick one of these
# instead of the app being wired to a single hardcoded
# WORKFLOW_TARGET_ROOT env var -- see Run#target_root, which still holds
# the actual path a launched run's supervisor process gets, just sourced
# from here now.
class Workspace < ApplicationRecord
  has_many :runs, dependent: :restrict_with_error
  has_many :workspace_memory_entries, dependent: :restrict_with_error
  has_many :workspace_chats, dependent: :destroy

  validates :name, presence: true, uniqueness: true
  validates :root_path, presence: true, uniqueness: true
  validate :source_checkout_is_not_changed_while_runs_are_active

  def self.default
    order(:created_at).first
  end

  # Gates RunsController#new/#create -- a workspace with no declared
  # protected paths is fail-closed (see StepPolicy#protected_path?), so no
  # real task run may start until its bootstrap project_init run declares
  # them, however briefly that takes.
  def initialized?
    protected_path_patterns.present?
  end

  # A workspace owns a project directory; its durable source checkout is the
  # conventional `main` child. Task runs receive sibling worktrees beneath
  # this directory, never inside the source checkout.
  def source_root
    Pathname(root_path).join("main").expand_path.to_s
  end

  private

  def source_checkout_is_not_changed_while_runs_are_active
    return unless will_save_change_to_root_path?
    return unless runs.active.exists?

    errors.add(:root_path, "cannot change while a run is active")
  end
end

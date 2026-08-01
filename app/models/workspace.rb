# A registered target project the orchestrator can be pointed at (e.g.
# simple-retail-planner). Runs launched from the ops UI pick one of these
# instead of the app being wired to a single hardcoded
# WORKFLOW_TARGET_ROOT env var -- see Run#target_root, which still holds
# the actual path a launched run's supervisor process gets, just sourced
# from here now.
class Workspace < ApplicationRecord
  has_many :runs, dependent: :restrict_with_error
  has_many :notifications, dependent: :destroy
  has_many :workspace_memory_entries, dependent: :restrict_with_error
  has_many :workspace_env_vars, dependent: :destroy
  has_one :terminal_session, dependent: :destroy
  has_one :workspace_admin_chat, dependent: :destroy

  validates :name, presence: true, uniqueness: true
  validates :root_path, presence: true, uniqueness: true
  validate :source_checkout_is_not_changed_while_runs_are_active

  def self.default
    order(:created_at).first
  end

  # Gates RunsController#new/#create until project_init has recorded the
  # source patterns that are protected by default.
  def initialized?
    protected_path_patterns.present?
  end

  # A workspace owns a project directory; its durable source checkout is the
  # conventional `main` child. Task runs receive sibling worktrees beneath
  # this directory, never inside the source checkout.
  def source_root
    Pathname(root_path).join("main").expand_path.to_s
  end

  # These patterns are readable by every worker but writable only by an
  # implementation worker. They deliberately describe source, configuration,
  # and test paths, never the entire checkout: dependency caches and generated
  # output must not become source merely because they sit beside it.
  def protected_write_patterns
    protected_path_patterns.select do |pattern|
      pattern.present? && !Pathname(pattern).absolute? && !Pathname(pattern).cleanpath.to_s.start_with?("../")
    end
  end

  private

  def source_checkout_is_not_changed_while_runs_are_active
    return unless will_save_change_to_root_path?
    return unless runs.active.exists?

    errors.add(:root_path, "cannot change while a run is active")
  end
end

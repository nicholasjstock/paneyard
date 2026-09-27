# A registered target project the orchestrator can be pointed at (e.g.
# simple-retail-planner). Runs launched from the ops UI pick one of these
# instead of the app being wired to a single hardcoded
# WORKFLOW_TARGET_ROOT env var -- see Run#target_root, which still holds
# the actual path a launched run's supervisor process gets, just sourced
# from here now.
class Workspace < ApplicationRecord
  has_many :runs, dependent: :restrict_with_error
  has_many :workspace_env_vars, dependent: :destroy
  has_one :workspace_admin_chat, dependent: :destroy

  validates :name, presence: true, uniqueness: true
  validates :root_path, presence: true, uniqueness: true
  validate :source_checkout_is_not_changed_while_runs_are_active
  validate :layout_is_valid

  # A blank layout is stored as NULL, which means the default. A browser
  # textarea submits CRLF line endings.
  normalizes :layout, with: ->(text) { text.gsub("\r\n", "\n").strip.presence }

  def self.default
    order(:created_at).first
  end

  # A workspace owns a project directory; its durable source checkout is the
  # conventional `main` child. Task runs receive sibling worktrees beneath
  # this directory, never inside the source checkout.
  def source_root
    Pathname(root_path).join("main").expand_path.to_s
  end

  private

  def layout_is_valid
    return if layout.blank?

    Orchestrator::WorkspaceLayout.errors_for(layout).each { |message| errors.add(:layout, message) }
  end

  def source_checkout_is_not_changed_while_runs_are_active
    return unless will_save_change_to_root_path?
    return unless runs.active.exists?

    errors.add(:root_path, "cannot change while a run is active")
  end
end

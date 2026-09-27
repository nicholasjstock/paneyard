# A registered target project the orchestrator can be pointed at (e.g.
# simple-retail-planner). Runs launched from the ops UI pick one of these
# instead of the app being wired to a single hardcoded
# WORKFLOW_TARGET_ROOT env var -- see Run#target_root, which still holds
# the actual path a launched run's supervisor process gets, just sourced
# from here now.
class Workspace < ApplicationRecord
  has_many :runs, dependent: :restrict_with_error
  has_many :workspace_env_vars, dependent: :destroy

  validates :name, presence: true, uniqueness: true
  validates :root_path, presence: true, uniqueness: true
  validate :source_checkout_is_not_changed_while_runs_are_active
  validate :layout_is_valid
  validate :root_path_is_inside_the_sandbox

  # A blank layout is stored as NULL, which means the default. A valid one is
  # stored as canonical YAML whatever form it arrived in (the workspace form's
  # layout editor submits JSON); an invalid one is kept as submitted so the
  # form can show it back beside its errors.
  normalizes :layout, with: ->(text) { normalize_layout(text) }

  def self.normalize_layout(text)
    text = text.gsub("\r\n", "\n").strip.presence
    return if text.nil?

    Orchestrator::WorkspaceLayout.dump(Orchestrator::WorkspaceLayout.parse(text))
  rescue Orchestrator::WorkspaceLayout::Invalid
    text
  end

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

  # A sandbox instance (Orchestrator::Sandbox) only manages scratch repos of
  # its own, so it can never be pointed at a real project's worktrees.
  def root_path_is_inside_the_sandbox
    return if root_path.blank? || Orchestrator::Sandbox.allows_path?(root_path)

    errors.add(:root_path, "must be inside the sandbox root #{Orchestrator::Sandbox.root}")
  end

  def source_checkout_is_not_changed_while_runs_are_active
    return unless will_save_change_to_root_path?
    return unless runs.active.exists?

    errors.add(:root_path, "cannot change while a run is active")
  end
end

# A registered repository the orchestrator runs jobs against: an existing git
# checkout, wherever it is and whatever it has checked out, plus the branch
# runs start from unless they name another (Run#base_branch). Runs never work
# in this checkout: herdr creates each run's worktree, where its own
# configuration puts worktrees (Orchestrator::GitWorktree), and Paneyard never
# deletes, resets or switches the checkout itself.
class Workspace < ApplicationRecord
  has_many :runs, dependent: :restrict_with_error

  validates :name, presence: true, uniqueness: true
  validates :repository_path, presence: true, uniqueness: true
  validates :default_base_branch, presence: true, format: { with: Orchestrator::GitRef::BRANCH_FORMAT, message: "is not a valid branch name" }
  validate :repository_is_not_changed_while_runs_are_active
  validate :layout_is_valid
  validate :repository_path_is_inside_the_sandbox

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

  private

  def layout_is_valid
    return if layout.blank?

    Orchestrator::WorkspaceLayout.errors_for(layout).each { |message| errors.add(:layout, message) }
  end

  # A sandbox instance (Orchestrator::Sandbox) only manages scratch repos of
  # its own, so it can never be pointed at a real project's worktrees.
  def repository_path_is_inside_the_sandbox
    return if repository_path.blank? || Orchestrator::Sandbox.allows_path?(repository_path)

    errors.add(:repository_path, "must be inside the sandbox root #{Orchestrator::Sandbox.root}")
  end

  def repository_is_not_changed_while_runs_are_active
    return unless will_save_change_to_repository_path?
    return unless runs.active.exists?

    errors.add(:repository_path, "cannot change while a run is active")
  end
end

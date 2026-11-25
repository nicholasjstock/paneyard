# A registered repository the orchestrator runs jobs against: an existing git
# checkout, wherever it is and whatever it has checked out, plus the branch
# runs start from unless they name another (Run#base_branch). Runs never work
# in this checkout: herdr creates each run's worktree, where its own
# configuration puts worktrees (Orchestrator::GitWorktree). The checkout is
# the operator's, and their lobby's (Lobby): Paneyard never deletes or resets
# it, and switches its branch only when the operator opens the lobby on
# another branch, and only when nothing can be lost
# (Orchestrator::LobbyOpen).
class Workspace < ApplicationRecord
  has_many :runs, dependent: :restrict_with_error
  has_many :lobbies, dependent: :destroy
  # Where the repository is checked out on each runner's machine. The local
  # runner's row is kept in step with repository_path (sync_local_checkout).
  has_many :checkouts, class_name: "WorkspaceCheckout", inverse_of: :workspace, dependent: :delete_all

  validates :name, presence: true, uniqueness: true
  validates :repository_path, presence: true, uniqueness: true
  validates :default_base_branch, presence: true, format: { with: Orchestrator::GitRef::BRANCH_FORMAT, message: "is not a valid branch name" }
  validate :repository_is_not_changed_while_runs_are_active
  validate :layout_is_valid
  validate :repository_path_is_inside_the_sandbox

  after_save :sync_local_checkout, if: :saved_change_to_repository_path?

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

  # The lobby Paneyard last knew to be open, live or not: LobbyOpen.status
  # says which.
  def open_lobby
    lobbies.open.order(:created_at).last
  end

  # The repository's checkout on runner's machine, a path the orchestrator
  # only hands back to that runner. The local runner's is repository_path
  # (its checkout row mirrors it); another runner's must have been recorded.
  def repository_path_for(runner)
    return repository_path if runner.nil? || runner.local?

    checkouts.find_by(runner:)&.repository_path ||
      raise(Orchestrator::Runner::Error, "workspace #{name.inspect} has no checkout on runner #{runner.name.inspect}")
  end

  private

  def sync_local_checkout
    checkout = checkouts.find_or_initialize_by(runner: RegisteredRunner.local)
    checkout.update!(repository_path:)
  end

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

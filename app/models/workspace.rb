# A registered repository the orchestrator runs jobs against: a name, the
# repository's origin, and the branch runs start from unless they name
# another (Run#base_branch).
#
# Where it is checked out is per runner (WorkspaceCheckout): each runner,
# the local one included, has an optional checkout of it, at whatever path
# that machine keeps it. A runner without one gets one when it first needs
# it, cloned from origin_url into its projects directory
# (Orchestrator::WorkspaceCheckout). Runs never work in a checkout: herdr
# creates each run's worktree of it, where its own configuration puts
# worktrees (Orchestrator::GitWorktree). A checkout is the operator's, and
# the local one their lobby's (Lobby): Paneyard never deletes or resets it,
# and switches its branch only when the operator opens the lobby on another
# branch, and only when nothing can be lost (Orchestrator::LobbyOpen).
class Workspace < ApplicationRecord
  # Removed in 20261127100000_make_workspaces_a_name_and_an_origin: the local
  # checkout is a workspace_checkouts row like any other runner's. Ignored so
  # a long-lived process with stale schema metadata does not write it.
  self.ignored_columns += %w[repository_path]

  has_many :runs, dependent: :restrict_with_error
  has_many :lobbies, dependent: :destroy
  # Where the repository is checked out on each runner's machine.
  has_many :checkouts, class_name: "WorkspaceCheckout", inverse_of: :workspace, dependent: :delete_all, autosave: true

  validates :name, presence: true, uniqueness: true
  validates :default_base_branch, presence: true, format: { with: Orchestrator::GitRef::BRANCH_FORMAT, message: "is not a valid branch name" }
  validate :layout_is_valid

  # A blank layout is stored as NULL, which means the default. A valid one is
  # stored as canonical YAML whatever form it arrived in (the workspace form's
  # layout editor submits JSON); an invalid one is kept as submitted so the
  # form can show it back beside its errors.
  normalizes :layout, with: ->(text) { normalize_layout(text) }
  normalizes :origin_url, with: ->(url) { url.strip.presence }

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

  # The repository's checkout on runner's machine (nil: the local runner's),
  # or nil when that runner has none yet. One recorded since the
  # association was loaded (a clone, a runner registering) is found too.
  def checkout_for(runner)
    runner ||= RegisteredRunner.local
    checkouts.target.find { |checkout| checkout.runner_id == runner.id } ||
      (persisted? ? checkouts.find_by(runner_id: runner.id) : nil)
  end

  def checkout_path(runner)
    checkout_for(runner)&.repository_path
  end

  # The checkout's path on runner's machine, a path the orchestrator only
  # hands back to that runner. Raises when that runner has none:
  # Orchestrator::WorkspaceCheckout.ensure! is what makes one.
  def repository_path_for(runner)
    runner ||= RegisteredRunner.local
    checkout_path(runner) ||
      raise(Orchestrator::Runner::Error, "workspace #{name.inspect} has no checkout on runner #{runner.name.inspect}")
  end

  # The local runner's checkout, or nil: what list_workspaces shows as
  # repositoryPath, the path an operator on this machine knows it by.
  def repository_path
    checkout_path(RegisteredRunner.local)
  end

  # Records (or moves) the local runner's checkout. The same as recording any
  # runner's (record_checkout), for the common case.
  def repository_path=(path)
    record_checkout(RegisteredRunner.local, path)
  end

  # Records (or moves) runner's checkout at path, saved with the workspace.
  def record_checkout(runner, path)
    checkout = checkout_for(runner) || checkouts.build(runner:)
    checkout.repository_path = path
    checkout
  end

  # The runners it is checked out on, local first, then by name.
  def checked_out_runners
    checkouts.map(&:runner).sort_by { |runner| [ runner.local? ? 0 : 1, runner.name ] }
  end

  private

  def layout_is_valid
    return if layout.blank?

    Orchestrator::WorkspaceLayout.errors_for(layout).each { |message| errors.add(:layout, message) }
  end
end

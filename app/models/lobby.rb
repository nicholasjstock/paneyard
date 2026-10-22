# A workspace's lobby: the operator's own agent session on the repository's
# checkout, where they integrate -- queue jobs, read their reports, merge their
# branches -- opened by Orchestrator::LobbyOpen from the plugin or /mcp/admin.
#
# Not a run. It holds no concurrency slot, has no capability (its CLI talks
# to /mcp/admin), never reports, and nothing reconciles or cleans it up: it
# is remembered only so that opening it again finds the one already open.
# closed_at is set when its launch fails, or when the next open finds its
# agent gone and replaces it; until then LobbyOpen.status says whether it is
# live.
class Lobby < ApplicationRecord
  belongs_to :workspace

  validates :branch, presence: true, format: { with: Orchestrator::GitRef::BRANCH_FORMAT, message: "is not a valid branch name" }
  validates :driver, inclusion: { in: Run::LAUNCHER_VARIANTS }

  scope :open, -> { where(closed_at: nil) }

  def open?
    closed_at.nil?
  end
end

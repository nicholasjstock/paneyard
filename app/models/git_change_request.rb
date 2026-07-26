# A worker's request that Rails exclude one path from the commit the
# committer eventually makes -- workers never get git write access
# themselves (see WorkerExecutionPolicy's unconditional .git exclusion).
# The committer reconciles these (list_git_change_requests) and decides
# which to actually honor via commit_run_changes's excludePaths; Rails
# then resolves each request to applied/dismissed based on that decision.
class GitChangeRequest < ApplicationRecord
  STATUSES = %w[requested applied dismissed].freeze

  belongs_to :run, foreign_key: :run_id, primary_key: :run_id, inverse_of: :git_change_requests

  validates :path, :reason, :requested_by_worker_id, presence: true
  validates :path, uniqueness: { scope: :run_id }
  validates :status, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: "requested") }

  def as_json(*)
    {
      path: path,
      reason: reason,
      requestedByWorkerId: requested_by_worker_id,
      status: status,
      createdAt: created_at.iso8601(3)
    }
  end
end

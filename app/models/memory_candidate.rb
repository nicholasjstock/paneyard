class MemoryCandidate < ApplicationRecord
  # confirmed/rejected/stale arrive with the future reconcile step -- every
  # candidate this increment creates is "proposed" and stays that way.
  STATUSES = %w[proposed].freeze

  belongs_to :run, foreign_key: :run_id, primary_key: :run_id
  belongs_to :worker, foreign_key: :worker_id, primary_key: :worker_id, optional: true

  validates :candidate_id, :run_id, :lineage_key, :status, :approach, :reason, presence: true
  validates :candidate_id, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  before_validation { self.candidate_id ||= SecureRandom.uuid }

  def as_json(*)
    {
      candidateId: candidate_id, runId: run_id, workerId: worker_id, lineageKey: lineage_key,
      role: role, status: status, approach: approach, reason: reason, nextApproach: next_approach,
      createdAt: created_at.iso8601(3)
    }
  end
end

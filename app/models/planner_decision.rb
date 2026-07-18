class PlannerDecision < ApplicationRecord
  STATUSES = %w[queued running awaiting_chaperone completed failed].freeze
  ACTIVE_STATUSES = %w[queued running awaiting_chaperone].freeze

  belongs_to :run, foreign_key: :run_id, primary_key: :run_id, inverse_of: :planner_decisions
  belongs_to :spawn_request, foreign_key: :spawn_request_id, primary_key: :request_id

  validates :decision_id, :run_id, :spawn_request_id, presence: true
  validates :decision_id, :spawn_request_id, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  before_validation :assign_decision_id, on: :create

  scope :active, -> { where(status: ACTIVE_STATUSES) }

  private

  def assign_decision_id
    self.decision_id ||= SecureRandom.uuid
  end
end

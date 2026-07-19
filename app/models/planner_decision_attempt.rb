class PlannerDecisionAttempt < ApplicationRecord
  DISPOSITIONS = %w[proposed accepted rejected needs_context needs_chaperone].freeze

  belongs_to :planner_decision

  validates :sequence, numericality: { only_integer: true, greater_than: 0 }
  validates :sequence, uniqueness: { scope: :planner_decision_id }
  validates :model_tier, :outcome, presence: true
  validates :disposition, inclusion: { in: DISPOSITIONS }
end

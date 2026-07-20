# A pure, immutable provenance edge -- not a second state machine
# duplicating what PlannerDecisionAttempt/StepAttempt already track for a
# step's own pass/fail. Just "this step claimed to work toward this
# criterion, at this time", so a criterion's full history is queryable.
class AcceptanceCriterionStep < ApplicationRecord
  belongs_to :acceptance_criterion
  belongs_to :run, foreign_key: :run_id, primary_key: :run_id

  validates :lineage_key, presence: true
end

class StepAttempt < ApplicationRecord
  OUTCOMES = %w[done blocked failed].freeze

  belongs_to :run, foreign_key: :run_id, primary_key: :run_id
  belongs_to :spawn_request, foreign_key: :spawn_request_id, primary_key: :request_id

  validates :attempt_id, :run_id, :spawn_request_id, :lineage_key, :mode, :outcome, :result, presence: true
  validates :attempt_id, uniqueness: true
  validates :outcome, inclusion: { in: OUTCOMES }

  before_validation { self.attempt_id ||= SecureRandom.uuid }
end

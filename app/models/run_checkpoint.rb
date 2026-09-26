# One session's report of where a run stands, written each time it goes idle.
#
# Append-only, and deliberately a row rather than a column on run_sessions: a
# session goes idle, the operator sends more work, it goes idle again, and each
# report describes only the interval since the previous one -- what was
# attempted, what landed, what broke, what state it left behind. Overwriting a
# single "latest result" field would keep the current state and throw the
# narrative away, so the sequence is the run's history and the newest row is
# its current state.
class RunCheckpoint < ApplicationRecord
  belongs_to :run
  belongs_to :run_session

  validates :outcome, inclusion: { in: RunSession::OUTCOMES }

  scope :chronological, -> { order(:created_at, :id) }
end

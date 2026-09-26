require "digest"

# The single execution record for one run: which herdr pane it is running in,
# which OS process, which CLI session, and how it ended. It replaces the old
# Worker registry -- a run no longer decomposes into a queue of per-step
# workers, it is one continuous interactive session that owns the job from
# start to finish.
#
# NOTE ON NAMING: `run_id` here is the integer foreign key to `runs.id`
# (standard Rails `t.references :run`), NOT the `runs.run_id` string natural
# key that the rest of this schema joins on. Reach the string through the
# association: `session.run.run_id`.
#
# herdr -- not Rails -- owns the pty and process lifecycle. This row only
# remembers where things are so Rails can reconcile, prompt, and clean up.
# See Orchestrator::RunSessionRunner.
class RunSession < ApplicationRecord
  # `status` describes what the session is doing; `ended_at` decides whether
  # it is still holding a concurrency slot. Keeping those separate matters:
  # "blocked" is a live state (the agent is waiting at a question in its own
  # pane, process still up, operator able to answer right there), while
  # outcome "blocked" is a terminal one (it gave up and handed the run back).
  # The partial unique index on run_sessions keys off ended_at for the same
  # reason, so anything that ends a session must set it.
  STATUSES = %w[starting running blocked done failed closed].freeze
  OUTCOMES = %w[done blocked failed].freeze

  belongs_to :run
  # This session's own checkpoints, oldest first -- see RunSessionRunner's use
  # of the last one to learn whether a session already reported success
  # before its pane or process disappeared.
  has_many :checkpoints, -> { order(:created_at, :id) }, class_name: "RunCheckpoint", inverse_of: :run_session

  validates :driver, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :outcome, inclusion: { in: OUTCOMES }, allow_nil: true

  scope :live, -> { where(ended_at: nil) }

  after_commit :broadcast_refresh

  def self.issue_capability
    token = SecureRandom.hex(32)
    [ token, Digest::SHA256.hexdigest(token) ]
  end

  def self.authenticate_capability(token)
    return if token.blank?

    live.find_by(capability_token_digest: Digest::SHA256.hexdigest(token))
  end

  def live?
    ended_at.nil?
  end

  def ended?
    !live?
  end

  # True once herdr no longer knows the pane, which is the one signal that
  # cannot be recovered from -- the operator closed it by hand, or the whole
  # herdr server restarted.
  def pane_gone?
    herdr_pane_id.blank?
  end

  private

  def broadcast_refresh
    Turbo::StreamsChannel.broadcast_refresh_to("run_#{run.run_id}") if run
  end
end

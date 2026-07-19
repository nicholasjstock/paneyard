require "digest"

class ChaperoneReview < ApplicationRecord
  STATUSES = %w[queued running completed failed].freeze
  ACTIONS = %w[continue_small promote stop].freeze
  SUBJECT_TYPES = %w[diagnosis planner].freeze

  belongs_to :run, foreign_key: :run_id, primary_key: :run_id

  validates :review_id, :run_id, :lineage_key, :token_digest, :expires_at, presence: true
  validates :review_id, :token_digest, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :action, inclusion: { in: ACTIONS }, allow_nil: true
  validates :subject_type, inclusion: { in: SUBJECT_TYPES }
  validates :subject_id, presence: true, if: -> { subject_type == "planner" }

  before_validation { self.review_id ||= SecureRandom.uuid }

  def self.issue!(run:, lineage_key:, step_attempt_ids:, subject_type: "diagnosis", subject_id: nil, summary: nil)
    token = SecureRandom.hex(32)
    review = create!(
      run:, lineage_key:, step_attempt_ids:, subject_type:, subject_id:, summary:, trigger_reason: summary,
      token_digest: digest(token), expires_at: 1.hour.from_now
    )
    [ review, token ]
  end

  def self.authenticate(token)
    return if token.blank?

    find_by(token_digest: digest(token), status: %w[queued running])&.then do |review|
      review if review.expires_at.future?
    end
  end

  def self.digest(token)
    Digest::SHA256.hexdigest(token)
  end

  def reissue_token!
    token = SecureRandom.hex(32)
    update!(token_digest: self.class.digest(token), expires_at: 1.hour.from_now)
    token
  end

  def record_tool_call!(tool_name)
    with_lock do
      self.tool_calls = tool_calls + [ { "tool" => tool_name, "at" => Time.current.iso8601(3) } ]
      save!
    end
  end
end

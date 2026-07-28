require "digest"

class ReplyReceivedReview < ApplicationRecord
  STATUSES = %w[queued running completed failed].freeze
  ACTIONS = %w[approved explain revise].freeze

  belongs_to :run, foreign_key: :run_id, primary_key: :run_id

  validates :review_id, :run_id, :user_question_id, :github_comment_id, :token_digest, :expires_at, presence: true
  validates :review_id, :token_digest, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :action, inclusion: { in: ACTIONS }, allow_nil: true

  before_validation { self.review_id ||= SecureRandom.uuid }

  def self.issue!(run:, user_question:, comment:)
    token = SecureRandom.hex(32)
    review = create!(
      run:, user_question_id: user_question.question_id, github_comment_id: comment.fetch("id").to_s,
      github_comment_author: comment.dig("user", "login") || "unknown", github_comment_body: comment.fetch("body"),
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

  def user_question
    UserQuestion.find_by(question_id: user_question_id)
  end

  def record_tool_call!(tool_name)
    with_lock do
      self.tool_calls = tool_calls + [ { "tool" => tool_name, "at" => Time.current.iso8601(3) } ]
      save!
    end
  end
end

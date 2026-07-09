# Replaces WorkflowUserQuestion (workflow-bus.ts). Wire format (#as_json)
# mirrors that TS type field-for-field.
class UserQuestion < ApplicationRecord
  PRIORITIES = %w[advisory blocking].freeze
  STATUSES = %w[open answered dismissed].freeze

  belongs_to :run, foreign_key: :run_id, primary_key: :run_id, optional: true, inverse_of: :user_questions

  validates :question_id, presence: true, uniqueness: true
  validates :run_id, :asked_by, :scope, :text, presence: true
  validates :priority, inclusion: { in: PRIORITIES }
  validates :status, inclusion: { in: STATUSES }

  before_validation :assign_question_id, on: :create
  before_validation :assign_asked_at, on: :create

  after_create_commit :publish_created_event
  after_update_commit :publish_answered_event

  scope :open_only, -> { where(status: "open") }

  def as_json(*)
    {
      questionId: question_id,
      runId: run_id,
      askedBy: asked_by,
      askedAt: asked_at.iso8601(3),
      scope: scope,
      text: text,
      context: context,
      priority: priority,
      status: status,
      tags: tags,
      answeredBy: answered_by,
      answeredAt: answered_at&.iso8601(3),
      answerText: answer_text
    }
  end

  private

  def assign_question_id
    self.question_id ||= SecureRandom.uuid
  end

  def assign_asked_at
    self.asked_at ||= Time.current
  end

  def publish_created_event
    BusEvent.publish("user_question.created", run_id: run_id, payload: {
      questionId: question_id, runId: run_id, askedBy: asked_by, scope: scope,
      priority: priority, context: context, tags: tags
    })
  end

  def publish_answered_event
    return unless saved_change_to_status? && status == "answered"

    BusEvent.publish("user_question.answered", run_id: run_id, payload: {
      questionId: question_id, runId: run_id, answeredBy: answered_by, answerText: answer_text
    })
  end
end

# Replaces WorkflowUserQuestion (workflow-bus.ts). Wire format (#as_json)
# mirrors that TS type field-for-field.
class UserQuestion < ApplicationRecord
  PRIORITIES = %w[advisory blocking].freeze
  STATUSES = %w[open answered dismissed].freeze
  DIAGNOSTIC_TEXT_LIMIT = 600

  belongs_to :run, foreign_key: :run_id, primary_key: :run_id, optional: true, inverse_of: :user_questions

  validates :question_id, presence: true, uniqueness: true
  validates :run_id, :asked_by, :scope, :text, presence: true
  validates :priority, inclusion: { in: PRIORITIES }
  validates :status, inclusion: { in: STATUSES }
  validate :at_most_one_open_blocking_question_per_run

  before_validation :assign_question_id, on: :create
  before_validation :assign_asked_at, on: :create

  after_create_commit :publish_created_event
  after_create_commit :enqueue_github_publication
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
      answerText: answer_text,
      githubCommentUrl: github_comment_url,
      githubPublishedAt: github_published_at&.iso8601(3),
      githubPublicationError: github_publication_error
    }
  end

  def as_diagnostic_json
    {
      questionId: question_id,
      runId: run_id,
      askedBy: asked_by,
      askedAt: asked_at.iso8601(3),
      scope: scope,
      text: truncate(text),
      priority: priority,
      status: status,
      tags: tags,
      answeredBy: answered_by,
      answeredAt: answered_at&.iso8601(3),
      answerText: truncate(answer_text),
      detailAvailable: context.present? || text.to_s.length > DIAGNOSTIC_TEXT_LIMIT || answer_text.to_s.length > DIAGNOSTIC_TEXT_LIMIT
    }
  end

  private

  # Backstop, not the primary control: every UserQuestion.create! call site
  # that opens a blocking question is expected to check Run#open_blocking_question?
  # first and skip instead of creating a second one (a duplicate would just
  # be noise once the operator is already the blocker -- see that method's
  # comment). This catches any call site that forgets to.
  def at_most_one_open_blocking_question_per_run
    return unless priority == "blocking" && status == "open" && run_id.present?

    scope = self.class.where(run_id: run_id, status: "open", priority: "blocking")
    scope = scope.where.not(id: id) if persisted?
    errors.add(:base, "run #{run_id} already has an open blocking question") if scope.exists?
  end

  def assign_question_id
    self.question_id ||= SecureRandom.uuid
  end

  def assign_asked_at
    self.asked_at ||= Time.current
  end

  def truncate(value)
    text = value.to_s
    text.length > DIAGNOSTIC_TEXT_LIMIT ? "#{text.first(DIAGNOSTIC_TEXT_LIMIT).rstrip}…" : text
  end

  def publish_created_event
    BusEvent.publish("user_question.created", run_id: run_id, payload: {
      questionId: question_id, runId: run_id, askedBy: asked_by, scope: scope,
      priority: priority, context: context, tags: tags
    })
  end

  def enqueue_github_publication
    PublishUserQuestionJob.perform_later(id) if run&.managed_worktree?
  end

  def publish_answered_event
    return unless saved_change_to_status? && status == "answered"

    BusEvent.publish("user_question.answered", run_id: run_id, payload: {
      questionId: question_id, runId: run_id, answeredBy: answered_by, answerText: answer_text
    })
  end
end

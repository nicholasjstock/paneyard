# Replaces WorkflowSpawnRequest (workflow-bus.ts) as the source of truth
# for "please spawn a worker/planner for this run" asks. Wire format
# (#as_json) intentionally mirrors that TS type field-for-field so the
# Node-side HTTP-backed bus client needs zero shape translation.
class SpawnRequest < ApplicationRecord
  PRIORITIES = %w[advisory blocking].freeze
  STATUSES = %w[open fulfilled dismissed].freeze
  DIAGNOSTIC_TEXT_LIMIT = 600

  belongs_to :run, foreign_key: :run_id, primary_key: :run_id, optional: true, inverse_of: :spawn_requests

  validates :request_id, presence: true, uniqueness: true
  validates :run_id, :asked_by, :scope, :text, :requested_role, presence: true
  validates :priority, inclusion: { in: PRIORITIES }
  validates :status, inclusion: { in: STATUSES }
  validates :model_tier, inclusion: { in: %w[small strong] }

  before_validation :assign_request_id, on: :create
  before_validation :assign_asked_at, on: :create

  after_create_commit :publish_created_event
  after_update_commit :publish_status_change_event

  scope :open_only, -> { where(status: "open") }

  def as_json(*)
    {
      requestId: request_id,
      runId: run_id,
      askedBy: asked_by,
      askedAt: asked_at.iso8601(3),
      scope: scope,
      text: text,
      context: context,
      requestedRole: requested_role,
      lineageKey: lineage_key,
      modelTier: model_tier,
      priority: priority,
      status: status,
      fulfilledBy: fulfilled_by,
      fulfilledAt: fulfilled_at&.iso8601(3),
      fulfillmentNote: fulfillment_note,
      fulfilledWorkerId: fulfilled_worker_id,
      dismissedBy: dismissed_by,
      dismissedAt: dismissed_at&.iso8601(3),
      dismissalNote: dismissal_note,
      tags: tags
    }
  end

  def as_diagnostic_json
    {
      requestId: request_id,
      runId: run_id,
      askedBy: asked_by,
      askedAt: asked_at.iso8601(3),
      scope: scope,
      text: truncate(text),
      requestedRole: requested_role,
      priority: priority,
      status: status,
      fulfilledWorkerId: fulfilled_worker_id,
      tags: tags,
      detailAvailable: context.present? || text.to_s.length > DIAGNOSTIC_TEXT_LIMIT
    }
  end

  private

  def assign_request_id
    self.request_id ||= SecureRandom.uuid
  end

  def assign_asked_at
    self.asked_at ||= Time.current
  end

  def truncate(value)
    text = value.to_s
    text.length > DIAGNOSTIC_TEXT_LIMIT ? "#{text.first(DIAGNOSTIC_TEXT_LIMIT).rstrip}…" : text
  end

  def publish_created_event
    BusEvent.publish("spawn_request.created", run_id: run_id, payload: {
      requestId: request_id, runId: run_id, askedBy: asked_by, scope: scope,
      requestedRole: requested_role, priority: priority, context: context, tags: tags
    })
  end

  def publish_status_change_event
    return unless saved_change_to_status?

    case status
    when "fulfilled"
      BusEvent.publish("spawn_request.fulfilled", run_id: run_id, payload: {
        requestId: request_id, runId: run_id, fulfilledBy: fulfilled_by,
        fulfillmentNote: fulfillment_note, fulfilledWorkerId: fulfilled_worker_id
      })
    when "dismissed"
      BusEvent.publish("spawn_request.dismissed", run_id: run_id, payload: {
        requestId: request_id, runId: run_id, dismissedBy: dismissed_by, dismissalNote: dismissal_note
      })
    end
  end
end

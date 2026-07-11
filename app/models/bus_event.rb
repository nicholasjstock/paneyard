# Source of truth for the unified activity feed. Events are generated
# centrally via #publish, called from the other models'
# after_create_commit/after_update_commit callbacks, and broadcast right
# here via Turbo Streams -- no separate bridge process involved.
class BusEvent < ApplicationRecord
  belongs_to :run, foreign_key: :run_id, primary_key: :run_id, optional: true, inverse_of: :bus_events

  validates :event_id, presence: true, uniqueness: true
  validates :event_type, presence: true

  before_validation :assign_event_id, on: :create

  after_create_commit :broadcast

  def self.publish(type, run_id:, payload:)
    create!(event_type: type, run_id: run_id, payload: payload)
  end

  def as_json(*)
    {
      eventId: event_id,
      at: created_at.iso8601(3),
      type: event_type,
      payload: payload
    }
  end

  private

  def assign_event_id
    self.event_id ||= SecureRandom.uuid
  end

  def broadcast
    workspace_id = run&.workspace_id

    Turbo::StreamsChannel.broadcast_refresh_to("run_#{run_id}") if run_id.present?

    case event_type
    when /\Aworker\./
      Turbo::StreamsChannel.broadcast_refresh_to("workspace_#{workspace_id}_workers") if workspace_id.present?
    when /\Auser_question\./
      Turbo::StreamsChannel.broadcast_refresh_to("workspace_#{workspace_id}_questions") if workspace_id.present?
    when /\Aspawn_request\./, "run.status"
      Turbo::StreamsChannel.broadcast_refresh_to("workspace_#{workspace_id}_runs") if workspace_id.present?
    end

    Turbo::StreamsChannel.broadcast_refresh_to("workspace_#{workspace_id}_events") if workspace_id.present?
  end
end

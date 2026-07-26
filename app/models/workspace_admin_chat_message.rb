# A single turn's user prompt or assistant transcript. Unlike TerminalSession
# (whose scrollback lives only in a raw pty log file), each admin-chat turn
# is a durable row: the assistant row accumulates normalized
# Orchestrator::WorkspaceAdminChat events as they stream in (see #apply_event!)
# so the full turn -- text, tool calls, file changes, errors -- survives a
# page reload without replaying the CLI.
class WorkspaceAdminChatMessage < ApplicationRecord
  ROLES = %w[user assistant].freeze
  STATUSES = %w[queued running completed failed cancelled].freeze

  belongs_to :workspace_admin_chat, touch: true

  validates :role, inclusion: { in: ROLES }
  validates :status, inclusion: { in: STATUSES }

  after_commit :broadcast_refresh

  # Folds one normalized WorkspaceAdminChatEvent (see
  # Orchestrator::WorkspaceAdminChat::Event) into this row's persisted state.
  # Called once per event as a turn streams in, so each call is its own
  # `update!` -- the row is the live, reloadable view of an in-progress turn.
  def apply_event!(event)
    event = event.deep_stringify_keys
    attrs = { events: events + [ event ] }

    case event["type"]
    when "assistant_delta"
      attrs[:content] = content.to_s + event["text"].to_s
    when "assistant_completed"
      attrs[:content] = event["text"].to_s
    when "turn_completed"
      attrs[:usage] = event["usage"] || {}
    when "error"
      attrs[:error_message] = event["message"]
    end

    update!(attrs)
  end

  private

  def broadcast_refresh
    Turbo::StreamsChannel.broadcast_refresh_to("workspace_admin_chat_#{workspace_admin_chat_id}")
  end
end

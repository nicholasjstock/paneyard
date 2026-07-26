module WorkspaceAdminChatsHelper
  VISIBLE_EVENT_TYPES = %w[tool_started tool_completed file_changed error session_reconstructed].freeze

  def admin_chat_visible_events(events)
    Array(events).select { |event| VISIBLE_EVENT_TYPES.include?(event["type"]) }
  end

  def admin_chat_event_summary(event)
    case event["type"]
    when "tool_started"
      [ "▸ #{event["name"]}", admin_chat_event_detail(event["detail"]) ].compact.join(" ")
    when "tool_completed"
      "✓ #{event["name"] || event["id"]} completed"
    when "file_changed"
      "✎ #{event["path"]}"
    when "error"
      "⚠ #{event["message"]}"
    when "session_reconstructed"
      "↻ #{event["message"]}"
    end
  end

  def admin_chat_event_detail(detail)
    return if detail.blank?

    detail.is_a?(String) ? detail.truncate(160) : detail.to_json.truncate(160)
  end
end

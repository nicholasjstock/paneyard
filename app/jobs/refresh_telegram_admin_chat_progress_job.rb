class RefreshTelegramAdminChatProgressJob < ApplicationJob
  queue_as :default

  def perform
    WorkspaceAdminChatMessage.where(role: "assistant", status: "running").where.not(telegram_conversation_id: nil).where.not(telegram_draft_id: nil).find_each do |message|
      refresh(message)
    end
  end

  private

  def refresh(message)
    message.with_lock do
      client = Telegram::Client.new
      return unless message.telegram_draft_id

    text = message.content.presence || "<tg-thinking>Working…</tg-thinking>"
    return if text == message.telegram_synced_content

    client.send_rich_message_draft(
      chat_id: message.telegram_conversation.telegram_chat_id, draft_id: message.telegram_draft_id, html: text
    )
    message.update!(telegram_synced_content: text)
    end
  end
end

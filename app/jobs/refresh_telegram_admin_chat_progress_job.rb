class RefreshTelegramAdminChatProgressJob < ApplicationJob
  queue_as :default

  MAX_TELEGRAM_MESSAGE_LENGTH = 4096

  def perform
    WorkspaceAdminChatMessage.where(role: "assistant", status: "running").where.not(telegram_conversation_id: nil).where.not(telegram_message_id: nil).find_each do |message|
      refresh(message)
    end
  end

  private

  def refresh(message)
    message.with_lock do
      client = Telegram::Client.new
      client.send_chat_action(chat_id: message.telegram_conversation.telegram_chat_id, action: "typing")

      text = message.content.to_s.first(MAX_TELEGRAM_MESSAGE_LENGTH)
      return if text.blank? || text == message.telegram_synced_content

      client.edit_message_text(
        chat_id: message.telegram_conversation.telegram_chat_id, message_id: message.telegram_message_id, text: text
      )
      message.update!(telegram_synced_content: text)
    end
  end
end

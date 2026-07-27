class DeliverTelegramAdminChatResponseJob < ApplicationJob
  queue_as :default

  def perform(message_id)
    message = WorkspaceAdminChatMessage.find(message_id)
    return unless message.role == "assistant" && message.telegram_conversation && message.telegram_delivered_at.nil?

    message.with_lock do
      return if message.telegram_delivered_at

      text = message.content.presence || message.error_message.presence || "The admin-chat turn finished without a response."
      Telegram::Client.new.send_message(chat_id: message.telegram_conversation.telegram_chat_id, text: text)
      message.update!(telegram_delivered_at: Time.current)
    end
  end
end

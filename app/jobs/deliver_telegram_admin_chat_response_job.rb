class DeliverTelegramAdminChatResponseJob < ApplicationJob
  queue_as :default
  MAX_TELEGRAM_MESSAGE_LENGTH = 4096

  def perform(message_id)
    message = WorkspaceAdminChatMessage.find(message_id)
    return unless message.role == "assistant" && message.telegram_conversation && message.telegram_delivered_at.nil?

    message.with_lock do
      return if message.telegram_delivered_at

      deliver(message)
      message.update!(telegram_delivered_at: Time.current)
    end
  end

  private

  def deliver(message)
    text = message.content.presence || message.error_message.presence || "The admin-chat turn finished without a response."
    chunks = text.scan(/.{1,#{MAX_TELEGRAM_MESSAGE_LENGTH}}/m)
    client = Telegram::Client.new
    chat_id = message.telegram_conversation.telegram_chat_id

    chunks.each { |chunk| client.send_rich_message(chat_id:, markdown: chunk) }
  end
end

class RefreshTelegramAdminChatProgressJob < ApplicationJob
  queue_as :default
  MAX_TELEGRAM_MESSAGE_LENGTH = 4096

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
      chunks = chunks_for(text)
      persist_completed_chunks(message, client, chunks)
      draft = chunks.last
      return if draft == message.telegram_synced_content

      client.send_rich_message_draft(
        chat_id: message.telegram_conversation.telegram_chat_id, draft_id: message.telegram_draft_id, html: draft
      )
      message.update!(telegram_synced_content: draft)
    end
  end

  def persist_completed_chunks(message, client, chunks)
    completed_characters = chunks[0...-1].sum(&:length)
    return unless completed_characters > message.telegram_persisted_characters

    offset = 0
    chunks_for(message.content.to_s).each do |chunk|
      break if offset + chunk.length > completed_characters

      if offset + chunk.length <= message.telegram_persisted_characters
        offset += chunk.length
        next
      end

      client.send_rich_message(chat_id: message.telegram_conversation.telegram_chat_id, markdown: chunk)
      message.telegram_persisted_characters += chunk.length
      offset += chunk.length
    end
    message.telegram_draft_id = SecureRandom.random_number(1..(2**63 - 1))
    message.telegram_synced_content = nil
    message.save!
  end

  def chunks_for(text)
    text.each_char.each_slice(MAX_TELEGRAM_MESSAGE_LENGTH).map(&:join)
  end
end

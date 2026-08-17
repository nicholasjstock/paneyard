class PollTelegramUpdatesJob < ApplicationJob
  queue_as :default

  def perform
    return unless Telegram::Configuration.polling_configured?

    cursor = TelegramUpdateCursor.for_bot
    cursor.with_lock do
      Telegram::Client.new.get_updates(offset: cursor.last_update_id + 1).sort_by { |update| update.fetch("update_id") }.each do |update|
        # A raise here (a malformed update, a Telegram API error mid-turn, a
        # transient DB issue) must never stop the cursor from advancing --
        # otherwise this exact update is refetched and retried every 5
        # seconds forever, wedging every later message behind it with no
        # visible symptom other than silence. Advance regardless, and make
        # a best-effort attempt to surface the failure back into the chat
        # it came from so it isn't purely a server-log-only event.
        begin
          Telegram::UpdateProcessor.call(update)
        rescue => e
          Rails.logger.error("PollTelegramUpdatesJob: update #{update['update_id']} failed: #{e.class}: #{e.message}")
          notify_failure(update, e)
        end
        cursor.update!(last_update_id: update.fetch("update_id"))
      end
    end
  end

  private

  def notify_failure(update, error)
    chat_id = update.dig("message", "chat", "id") || update.dig("callback_query", "message", "chat", "id")
    return if chat_id.blank?

    Telegram::Client.new.send_message(chat_id: chat_id, text: "Something went wrong handling that: #{error.message}")
  rescue StandardError
    nil
  end
end

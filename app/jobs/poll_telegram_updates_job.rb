class PollTelegramUpdatesJob < ApplicationJob
  queue_as :default

  def perform
    return unless Telegram::Configuration.polling_configured?

    cursor = TelegramUpdateCursor.for_bot
    cursor.with_lock do
      Telegram::Client.new.get_updates(offset: cursor.last_update_id + 1).sort_by { |update| update.fetch("update_id") }.each do |update|
        Telegram::UpdateProcessor.call(update)
        cursor.update!(last_update_id: update.fetch("update_id"))
      end
    end
  end
end

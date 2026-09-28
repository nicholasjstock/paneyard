module RemoteControl
  module Adapters
    module Telegram
      # One getUpdates round: every message since the durable cursor
      # (TelegramUpdateCursor) goes to RemoteControl::Processor, oldest first.
      # getUpdates hands each update to one poller only, which is why two
      # instances must never share a bot.
      class Poller
        def self.call(adapter: Adapter.new)
          new(adapter).call
        end

        def initialize(adapter)
          @adapter = adapter
        end

        def call
          return unless @adapter.enabled?

          Commands.publish(@adapter)
          cursor = TelegramUpdateCursor.for_bot
          cursor.with_lock do
            @adapter.client.get_updates(offset: cursor.last_update_id + 1).sort_by { |update| update.fetch("update_id") }.each do |update|
              process(update)
              cursor.update!(last_update_id: update.fetch("update_id"))
            end
          end
        end

        private

        # A raise here (a malformed update, a Telegram API error mid-turn, a
        # transient DB issue) must never stop the cursor from advancing --
        # otherwise this exact update is refetched and retried every 5 seconds
        # forever, wedging every later message behind it with no visible
        # symptom other than silence. Advance regardless, and make a
        # best-effort attempt to surface the failure back into the chat it
        # came from so it isn't purely a server-log-only event.
        def process(update)
          message = @adapter.message_from(update)
          Processor.call(@adapter, message) if message
        rescue => error
          Rails.logger.error("[remote_control] telegram: update #{update['update_id']} failed: #{error.class}: #{error.message}")
          notify_failure(message, error)
        end

        def notify_failure(message, error)
          return if message.nil? || !@adapter.authorized?(message.user_id)

          @adapter.send_text(message.chat_id, "Something went wrong handling that: #{error.message}")
        rescue StandardError
          nil
        end
      end
    end
  end
end

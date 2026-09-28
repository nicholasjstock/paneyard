module RemoteControl
  module Adapters
    module Telegram
      # The bot token and allow-list: Rails credentials (telegram.bot_token,
      # telegram.allowed_user_ids) or TELEGRAM_BOT_TOKEN /
      # TELEGRAM_ALLOWED_USER_IDS.
      module Configuration
        module_function

        # A sandbox instance (Orchestrator::Sandbox) must not poll unless it was
        # started with a bot of its own (bin/sandbox start --telegram):
        # getUpdates hands each message to one poller only, so a second one
        # sharing the bot would take the operator's messages away from
        # production. Even then it never falls back to credentials, which hold
        # production's bot.
        def bot_token
          return nil unless Orchestrator::Sandbox.allows_remote_control?("telegram")

          ENV["TELEGRAM_BOT_TOKEN"].presence || credential(:bot_token)
        end

        def allowed_user_ids
          raw = ENV["TELEGRAM_ALLOWED_USER_IDS"].presence || credential(:allowed_user_ids)
          Array(raw.is_a?(String) ? raw.split(",") : raw).map(&:to_s).map(&:strip).reject(&:blank?)
        end

        def configured?
          bot_token.present? && allowed_user_ids.any?
        end

        def credential(key)
          return nil if Orchestrator::Sandbox.enabled?

          Rails.application.credentials.dig(:telegram, key)
        end
      end
    end
  end
end

module RemoteControl
  module Adapters
    module Telegram
      # The bot token and allow-list: TELEGRAM_BOT_TOKEN and
      # TELEGRAM_ALLOWED_USER_IDS, from the environment only -- the herdr
      # plugin's .env (PaneyardPlugin::EnvFile), or bin/service's shell. Never
      # Rails credentials.
      module Configuration
        module_function

        # A sandbox instance (Orchestrator::Sandbox) must not poll unless it was
        # started with a bot of its own (bin/sandbox start --telegram):
        # getUpdates hands each message to one poller only, so a second one
        # sharing the bot would take the operator's messages away from
        # production.
        def bot_token
          return nil unless Orchestrator::Sandbox.allows_remote_control?("telegram")

          ENV["TELEGRAM_BOT_TOKEN"].presence
        end

        def allowed_user_ids
          ENV["TELEGRAM_ALLOWED_USER_IDS"].to_s.split(",").map(&:strip).reject(&:blank?)
        end

        def configured?
          bot_token.present? && allowed_user_ids.any?
        end
      end
    end
  end
end

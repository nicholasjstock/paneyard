module Telegram
  module Configuration
    module_function

    # A sandbox instance (Orchestrator::Sandbox) must not poll unless it was
    # started with a bot of its own (bin/sandbox start --telegram): getUpdates
    # hands each message to one poller only, so a second one sharing the bot
    # would take the operator's messages away from production.
    def bot_token
      return nil if Orchestrator::Sandbox.enabled? && !Orchestrator::Sandbox.real_telegram?

      ENV["TELEGRAM_BOT_TOKEN"].presence || Rails.application.credentials.dig(:telegram, :bot_token)
    end

    def allowed_user_ids
      raw = ENV["TELEGRAM_ALLOWED_USER_IDS"].presence || Rails.application.credentials.dig(:telegram, :allowed_user_ids)
      Array(raw.is_a?(String) ? raw.split(",") : raw).map(&:to_s).map(&:strip).reject(&:blank?)
    end

    def authorized_user?(telegram_user_id)
      allowed_user_ids.include?(telegram_user_id.to_s)
    end

    def polling_configured?
      bot_token.present? && allowed_user_ids.any?
    end
  end
end

module Telegram
  module Configuration
    module_function

    def bot_token
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

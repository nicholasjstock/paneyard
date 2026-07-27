require "net/http"
require "uri"

module Telegram
  class Client
    API_URL = "https://api.telegram.org".freeze

    def initialize(token: Configuration.bot_token, api_url: ENV.fetch("TELEGRAM_BOT_API_URL", API_URL))
      @token = token
      @api_url = api_url.delete_suffix("/")
    end

    def send_message(chat_id:, text:, reply_markup: nil)
      call("sendMessage", chat_id:, text:, reply_markup:)
    end

    def answer_callback_query(callback_query_id:)
      call("answerCallbackQuery", callback_query_id:)
    end

    def set_webhook(url:)
      call(
        "setWebhook", url:, secret_token: Configuration.webhook_secret,
        allowed_updates: %w[message callback_query], drop_pending_updates: true
      )
    end

    private

    def call(method, **params)
      raise "Telegram is not configured" if @token.blank?

      uri = URI("#{@api_url}/bot#{@token}/#{method}")
      response = Net::HTTP.post(uri, params.compact.to_json, "Content-Type" => "application/json")
      body = JSON.parse(response.body)
      raise "Telegram #{method} failed: #{body['description'] || response.code}" unless response.is_a?(Net::HTTPSuccess) && body["ok"]

      body["result"]
    end
  end
end

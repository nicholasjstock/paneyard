require "net/http"
require "uri"

module Telegram
  class Client
    API_URL = "https://api.telegram.org".freeze
    # Telegram's own cap on one message's text, after entity parsing.
    MAX_MESSAGE_LENGTH = 4096

    def initialize(token: Configuration.bot_token, api_url: ENV.fetch("TELEGRAM_BOT_API_URL", API_URL))
      @token = token
      @api_url = api_url.delete_suffix("/")
    end

    def send_message(chat_id:, text:, parse_mode: nil)
      call("sendMessage", chat_id:, text:, parse_mode:)
    end

    # Renders a checkpoint's Markdown (headings, tables, fences) natively.
    # Confirmed to deliver against this bot in production.
    def send_rich_message(chat_id:, markdown:)
      call("sendRichMessage", chat_id:, rich_message: { markdown: })
    end

    def get_updates(offset:)
      call("getUpdates", offset:, timeout: 0, allowed_updates: %w[message])
    end

    def delete_webhook
      call("deleteWebhook", drop_pending_updates: false)
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

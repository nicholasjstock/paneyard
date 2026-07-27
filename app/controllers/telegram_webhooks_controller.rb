class TelegramWebhooksController < ActionController::Base
  skip_forgery_protection

  def create
    return head :not_found unless Telegram::Configuration.configured?
    return head :unauthorized unless valid_secret?

    Telegram::UpdateProcessor.call(params.to_unsafe_h)
    head :ok
  rescue JSON::ParserError, ActionController::BadRequest
    head :bad_request
  end

  private

  def valid_secret?
    supplied = request.headers["X-Telegram-Bot-Api-Secret-Token"].to_s
    expected = Telegram::Configuration.webhook_secret.to_s
    expected.present? && ActiveSupport::SecurityUtils.secure_compare(supplied, expected)
  end
end

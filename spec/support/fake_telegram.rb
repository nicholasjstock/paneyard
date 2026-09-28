# Runs a FakeTelegram::Server for the duration of an example and points the
# real Telegram adapter at it (TELEGRAM_BOT_API_URL, a bot token, and an
# allow-list of the operator, user 42):
#
#   it "...", :fake_telegram do
#     fake_telegram.say("/panes")
#     PollTelegramUpdatesJob.perform_now
#     fake_telegram.texts.last
#   end
module FakeTelegramHelper
  def fake_telegram
    @fake_telegram
  end
end

RSpec.configure do |config|
  config.include FakeTelegramHelper

  config.around(:each, :fake_telegram) do |example|
    @fake_telegram = FakeTelegram::Server.new.start
    env = {
      "TELEGRAM_BOT_API_URL" => @fake_telegram.url,
      "TELEGRAM_BOT_TOKEN" => @fake_telegram.token,
      "TELEGRAM_ALLOWED_USER_IDS" => "42"
    }
    original = env.keys.index_with { |key| ENV[key] }
    env.each { |key, value| ENV[key] = value }
    example.run
  ensure
    original&.each { |key, value| ENV[key] = value }
    @fake_telegram&.stop
  end
end

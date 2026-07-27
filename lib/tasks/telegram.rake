namespace :telegram do
  namespace :webhook do
    desc "Register the Telegram webhook (WEBHOOK_URL=https://app.example.com/integrations/telegram/webhook)"
    task set: :environment do
      url = ENV.fetch("WEBHOOK_URL")
      Telegram::Client.new.set_webhook(url:)
      puts "Telegram webhook registered for #{url}"
    end
  end
end

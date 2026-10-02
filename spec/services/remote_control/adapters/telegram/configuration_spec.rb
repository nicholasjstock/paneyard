require "rails_helper"

RSpec.describe RemoteControl::Adapters::Telegram::Configuration do
  around do |example|
    example.run
  ensure
    %w[TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_USER_IDS].each { |key| ENV.delete(key) }
  end

  it "reads the bot and its allow-list from the environment (the plugin's .env)" do
    ENV["TELEGRAM_BOT_TOKEN"] = "123:abc"
    ENV["TELEGRAM_ALLOWED_USER_IDS"] = " 42, 7 ,"

    expect(described_class.bot_token).to eq("123:abc")
    expect(described_class.allowed_user_ids).to eq(%w[42 7])
    expect(described_class.configured?).to be(true)
  end

  it "never reads Rails credentials, even when they hold a bot" do
    allow(Rails.application.credentials).to receive(:dig).and_return("123:from-credentials")
    allow(Rails.application.credentials).to receive(:telegram).and_return(bot_token: "123:from-credentials", allowed_user_ids: [ 42 ])

    expect(described_class.bot_token).to be_nil
    expect(described_class.allowed_user_ids).to eq([])
    expect(described_class.configured?).to be(false)
  end
end

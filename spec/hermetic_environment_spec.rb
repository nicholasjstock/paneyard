require "rails_helper"
require "open3"

# Specs must not depend on the machine running them. The operator's main
# checkout has config/master.key and real credentials, and a run session's
# shell may carry the operator's environment (their Telegram bot); neither may
# reach a spec.
RSpec.describe "The spec environment" do
  it "never reads the real credentials, even where config/master.key could decrypt them" do
    content_path = Rails.application.credentials.content_path

    expect(content_path).not_to eq(Rails.root.join("config/credentials.yml.enc"))
    expect(content_path).not_to exist
    expect(Rails.application.credentials.config).to eq({})
    expect(Rails.application.credentials.dig(:telegram, :bot_token)).to be_nil
  end

  it "has no Telegram bot or allow-list of its own outside :fake_telegram" do
    expect(RemoteControl::Adapters::Telegram::Configuration.bot_token).to be_nil
    expect(RemoteControl::Adapters::Telegram::Configuration.allowed_user_ids).to eq([])
  end

  it "drops the operator's Telegram settings from the shell it was started in" do
    leaked = %w[TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_USER_IDS TELEGRAM_BOT_API_URL PANEYARD_SANDBOX_TELEGRAM]
    env = leaked.index_with { "leaked" }
    script = %(require "rspec/core"; require "./spec/spec_helper"; print #{leaked.inspect}.filter { |key| ENV.key?(key) }.join(","))

    out, status = Open3.capture2(env, RbConfig.ruby, "-e", script, chdir: Rails.root.to_s)

    expect(status).to be_success
    expect(out).to eq("")
  end
end

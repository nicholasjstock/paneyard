require "rails_helper"

RSpec.describe "Telegram webhooks", type: :request do
  before do
    allow(Telegram::Configuration).to receive(:configured?).and_return(true)
    allow(Telegram::Configuration).to receive(:webhook_secret).and_return("telegram-secret")
  end

  it "accepts a webhook with the configured Telegram secret" do
    expect(Telegram::UpdateProcessor).to receive(:call).with(hash_including("update_id" => 1))

    post "/integrations/telegram/webhook", params: { update_id: 1, message: {} }, as: :json,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" }

    expect(response).to have_http_status(:ok)
  end

  it "rejects a webhook with the wrong secret" do
    expect(Telegram::UpdateProcessor).not_to receive(:call)

    post "/integrations/telegram/webhook", params: { update_id: 1 }, as: :json,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "wrong" }

    expect(response).to have_http_status(:unauthorized)
  end
end

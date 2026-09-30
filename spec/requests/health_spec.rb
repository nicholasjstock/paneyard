require "rails_helper"

RSpec.describe "Health endpoint", type: :request do
  it "identifies the orchestrator service explicitly" do
    get "/up"

    expect(response).to have_http_status(:ok)
    expect(response.headers["X-Paneyard-Service"]).to eq("paneyard")
    expect(response.parsed_body).to include("service" => "paneyard")
  end
end

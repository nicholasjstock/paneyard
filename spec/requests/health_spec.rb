require "rails_helper"

RSpec.describe "Health endpoint", type: :request do
  it "identifies the orchestrator service explicitly" do
    get "/up"

    expect(response).to have_http_status(:ok)
    expect(response.headers["X-Workflow-Service"]).to eq("workflow-orchestrator")
    expect(response.parsed_body).to include("service" => "workflow-orchestrator")
  end
end

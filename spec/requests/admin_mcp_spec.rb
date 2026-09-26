require "rails_helper"

RSpec.describe "the admin MCP endpoint", type: :request do
  def post_mcp(body)
    post "/mcp/admin",
      params: JSON.generate(body),
      headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json, text/event-stream" }
  end

  it "accepts requests with no credentials at all -- this endpoint is deliberately unauthenticated" do
    post_mcp(jsonrpc: "2.0", id: 1, method: "tools/list")

    expect(response).not_to have_http_status(:unauthorized)
  end

  it "exposes exactly the external tool set" do
    names = Orchestrator::AdminMcpServer::TOOLS.map(&:tool_name)

    expect(names).to contain_exactly("ping_tool", "queue_run", "list_runs", "get_run")
  end
end

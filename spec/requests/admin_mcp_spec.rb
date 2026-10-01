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

    expect(names).to contain_exactly("ping_tool", "queue_run", "list_runs", "get_run", "list_workspaces", "register_workspace",
      "update_workspace_layout", "close_session")
  end

  it "tells clients how to find or register the workspace before queuing" do
    host! "127.0.0.1"
    post_mcp(jsonrpc: "2.0", id: 1, method: "initialize",
      params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "spec", version: "1" } })

    body = response.body
    body = body.lines.find { |line| line.start_with?("data:") }.delete_prefix("data:") if body.start_with?("event:", "data:")
    expect(JSON.parse(body).dig("result", "instructions")).to include("list_workspaces", "register_workspace", "queue_run")
  end

  it "keeps the admin mutations off the run endpoint" do
    expect(Orchestrator::RunMcpServer::TOOLS).not_to include(
      McpTools::RegisterWorkspaceTool, McpTools::UpdateWorkspaceLayoutTool, McpTools::CloseSessionTool
    )
  end

  describe "register_workspace" do
    before { host! "127.0.0.1" }

    # The full handshake a real client makes, then the call; the raw result,
    # since a failed registration is an error result the caller must read.
    def register(path)
      headers = { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json, text/event-stream" }
      post "/mcp/admin", headers:, params: JSON.generate(
        jsonrpc: "2.0", id: 1, method: "initialize",
        params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "spec", version: "1" } }
      )
      headers["HTTP_MCP_SESSION_ID"] = response.headers["mcp-session-id"]
      post "/mcp/admin", headers:, params: JSON.generate(jsonrpc: "2.0", method: "notifications/initialized")
      post "/mcp/admin", headers:, params: JSON.generate(
        jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "register_workspace", arguments: { path: } }
      )
      body = response.body
      body = body.lines.find { |line| line.start_with?("data:") }.delete_prefix("data:") if body.start_with?("event:", "data:")
      JSON.parse(body).fetch("result")
    end

    it "registers an existing checkout over the wire from its path alone" do
      repository = File.realpath(create_source_checkout(name: "over-the-wire"))

      result = register(repository)

      expect(result["isError"]).to be_falsey
      expect(result["structuredContent"]).to include(
        "name" => "over-the-wire", "repositoryPath" => repository, "defaultBaseBranch" => "main",
        "originUrl" => "https://example.test/paneyard.git"
      )
      expect(Workspace.find_by(name: "over-the-wire")&.repository_path).to eq(repository)
    end

    it "creates nothing for a directory that is not a checkout, and says why" do
      empty = Dir.mktmpdir("no-checkout")

      result = register(empty)

      expect(result["isError"]).to be(true)
      expect(result["structuredContent"]["problems"].map { |problem| problem["code"] }).to eq(%w[not_git])
      expect(Workspace.count).to eq(0)
    end
  end
end

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

    expect(names).to contain_exactly("ping_tool", "queue_run", "list_runs", "get_run", "list_workspaces", "list_models", "register_workspace",
      "update_workspace_layout", "close_session", "reopen_session", "update_run_dependencies")
  end

  it "tells clients how to find or register the workspace before queuing" do
    host! "127.0.0.1"
    post_mcp(jsonrpc: "2.0", id: 1, method: "initialize",
      params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "spec", version: "1" } })

    body = response.body
    body = body.lines.find { |line| line.start_with?("data:") }.delete_prefix("data:") if body.start_with?("event:", "data:")
    expect(JSON.parse(body).dig("result", "instructions")).to include("list_workspaces", "register_workspace", "queue_run")
  end

  # An operator's own client may sit idle for hours, and stays connected
  # while Paneyard restarts; neither may make it 404 (the mcp gem's stateful
  # default forgot a session after 30 idle minutes, and all of them on a restart).
  it "keeps answering a client long idle, or connected before a restart" do
    host! "127.0.0.1"
    post_mcp(jsonrpc: "2.0", id: 1, method: "initialize",
      params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "spec", version: "1" } })
    expect(response).to have_http_status(:ok)
    later = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 6.hours
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(later)

    post "/mcp/admin", params: JSON.generate(jsonrpc: "2.0", id: 2, method: "tools/list"),
      headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json, text/event-stream",
                 "HTTP_MCP_SESSION_ID" => SecureRandom.uuid }

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig("result", "tools")).to be_present
  end

  it "keeps the admin mutations off the run endpoint" do
    expect(Orchestrator::RunMcpServer::TOOLS).not_to include(
      McpTools::RegisterWorkspaceTool, McpTools::UpdateWorkspaceLayoutTool, McpTools::CloseSessionTool,
      McpTools::ReopenSessionTool, McpTools::UpdateRunDependenciesTool
    )
  end

  # The full handshake a real client makes, then the call; the raw result,
  # since a failed call is an error result the caller must read.
  def call_tool(name, **arguments)
    headers = { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json, text/event-stream" }
    post "/mcp/admin", headers:, params: JSON.generate(
      jsonrpc: "2.0", id: 1, method: "initialize",
      params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "spec", version: "1" } }
    )
    headers["HTTP_MCP_SESSION_ID"] = response.headers["mcp-session-id"]
    post "/mcp/admin", headers:, params: JSON.generate(jsonrpc: "2.0", method: "notifications/initialized")
    post "/mcp/admin", headers:, params: JSON.generate(
      jsonrpc: "2.0", id: 2, method: "tools/call", params: { name:, arguments: }
    )
    body = response.body
    body = body.lines.find { |line| line.start_with?("data:") }.delete_prefix("data:") if body.start_with?("event:", "data:")
    JSON.parse(body).fetch("result")
  end

  describe "reopen_session" do
    before { host! "127.0.0.1" }

    let(:workspace) { create_workspace(prefix: "reopen") }
    let(:run) do
      create_run(workspace:, prefix: "reopen", status: "completed", worktree_name: "fix-a1b2", branch_name: "paneyard/fix-a1b2",
        source_root: workspace.repository_path, target_root: "/worktrees/fix-a1b2")
    end

    it "queues a closed run again and says which worktree it will get" do
      allow(Orchestrator::Runner.local).to receive(:worktree_registered?).and_return(false)
      allow(Orchestrator::Runner.local).to receive(:branch_exists?).and_return(true)

      result = call_tool("reopen_session", runId: run.run_id, workspace: workspace.name)

      expect(result["isError"]).to be_falsey
      expect(result["structuredContent"]).to include("runId" => run.run_id, "status" => "queued", "worktree" => "recreated",
        "branch" => "paneyard/fix-a1b2", "queuedBehind" => 0, "capacity" => include("limit" => 4))
      expect(run.reload.status).to eq("queued")
    end

    it "explains why a run cannot be reopened" do
      _run, _session = create_run_and_session(run:)

      result = call_tool("reopen_session", runId: run.run_id, workspace: workspace.name)

      expect(result["isError"]).to be(true)
      expect(result["structuredContent"]).to include("error" => "not_reopenable", "message" => include("still has a live session"))
    end
  end

  describe "register_workspace" do
    before { host! "127.0.0.1" }

    def register(path)
      call_tool("register_workspace", path:)
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

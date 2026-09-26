require "rails_helper"

RSpec.describe "the run MCP endpoint", type: :request do
  def post_mcp(token)
    post "/mcp/run",
      params: JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/list"),
      headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json, text/event-stream" }
        .merge(token ? { "HTTP_AUTHORIZATION" => "Bearer #{token}" } : {})
  end

  it "rejects a request with no capability at all" do
    post_mcp(nil)

    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects an unknown capability" do
    post_mcp(SecureRandom.hex(32))

    expect(response).to have_http_status(:unauthorized)
  end

  # A session's capability dies with the session: once a run is over, its
  # token must not still reach the orchestrator.
  it "rejects the capability of a session that has ended" do
    token, digest = RunSession.issue_capability
    run = create_run(prefix: "mcp-endpoint")
    run.run_sessions.create!(
      driver: "claude", status: "done", outcome: "done", capability_token_digest: digest, ended_at: Time.current
    )

    post_mcp(token)

    expect(response).to have_http_status(:unauthorized)
  end

  # Past the capability gate the MCP transport owns the exchange (it enforces
  # its own initialize handshake), so this asserts only what this endpoint is
  # responsible for: a live session is not turned away.
  it "accepts a live session's capability and hands it to the transport" do
    token, digest = RunSession.issue_capability
    run = create_run(prefix: "mcp-endpoint")
    run.run_sessions.create!(driver: "claude", status: "running", capability_token_digest: digest)

    post_mcp(token)

    expect(response).not_to have_http_status(:unauthorized)
  end

  it "exposes exactly the run session tool set, and nothing planner-era" do
    names = Orchestrator::RunMcpServer::TOOLS.map(&:tool_name)

    expect(names).to contain_exactly(
      "ping_tool", "report_idle", "write_workflow_artifact", "read_workflow_artifact",
      "get_project_memory", "record_project_memory_entry", "record_workspace_env_var",
      "record_project_setup", "record_protected_paths"
    )
  end
end

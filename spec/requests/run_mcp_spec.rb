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

  # A session often waits on the operator for hours between reports, and
  # Paneyard restarts to apply new code; neither may cost it its next
  # report_idle (the mcp gem's stateful default forgot a session after 30
  # idle minutes, and every session on a restart, answering 404).
  describe "across idle hours and restarts" do
    let(:headers) { { "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json, text/event-stream" } }

    def rpc(endpoint, token, body, session_id: nil)
      env = headers.merge("HTTP_HOST" => "127.0.0.1:3000", "HTTP_AUTHORIZATION" => "Bearer #{token}",
        input: JSON.generate({ jsonrpc: "2.0" }.merge(body)))
      env["HTTP_MCP_SESSION_ID"] = session_id if session_id
      Rack::MockRequest.new(endpoint).post("/", env)
    end

    def handshake(endpoint, token)
      response = rpc(endpoint, token, { id: 1, method: "initialize",
        params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "spec", version: "1" } } })
      expect(response.status).to eq(200)
      rpc(endpoint, token, { method: "notifications/initialized" }, session_id: response["mcp-session-id"])
      response["mcp-session-id"]
    end

    def report_idle(endpoint, token, session_id)
      rpc(endpoint, token, { id: 2, method: "tools/call",
        params: { name: "report_idle", arguments: { outcome: "done", summary: "finished" } } }, session_id:)
    end

    def live_session_token
      token, digest = RunSession.issue_capability
      create_run_and_session(prefix: "mcp-idle").last.update!(capability_token_digest: digest)
      token
    end

    let!(:token) { live_session_token }

    it "answers a session's report long past the old 30-minute idle timeout" do
      endpoint = Orchestrator::RunMcpEndpoint.new
      session_id = handshake(endpoint, token)
      later = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 6.hours
      allow(Process).to receive(:clock_gettime).and_call_original
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(later)

      response = report_idle(endpoint, token, session_id)

      expect(response.status).to eq(200)
      expect(JSON.parse(response.body).dig("result", "isError")).to be_falsey
      expect(RunSession.find_by(capability_token_digest: Digest::SHA256.hexdigest(token)).run.checkpoints.count).to eq(1)
    end

    it "answers a session that connected before a restart, Mcp-Session-Id and all" do
      handshake(Orchestrator::RunMcpEndpoint.new, token)

      response = report_idle(Orchestrator::RunMcpEndpoint.new, token, SecureRandom.uuid)

      expect(response.status).to eq(200)
      expect(JSON.parse(response.body).dig("result", "isError")).to be_falsey
    end

    # The endpoint used to cache a transport per run session, each with its
    # own session-reaper thread, and never let go of one when its session
    # ended. Now nothing outlives the request.
    it "keeps nothing of a session once its requests are answered" do
      endpoint = Orchestrator::RunMcpEndpoint.new
      handshake(endpoint, token)
      threads = Thread.list.size

      3.times { handshake(endpoint, live_session_token) }

      expect(Thread.list.size).to eq(threads)
      expect(endpoint.instance_variables).to eq([ :@allowed_hosts ])
    end
  end

  it "exposes exactly the run session tool set, and nothing planner-era" do
    names = Orchestrator::RunMcpServer::TOOLS.map(&:tool_name)

    expect(names).to contain_exactly(
      "report_idle", "job_finished", "queue_run", "list_runs", "get_run", "list_workspaces"
    )
  end
end

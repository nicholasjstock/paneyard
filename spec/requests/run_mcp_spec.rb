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

  describe "job_finished acknowledgment" do
    let(:token) { RunSession.issue_capability.first }
    let(:run) { create_run(prefix: "mcp-finalization", branch_name: "paneyard/finished", worktree_name: "finished") }
    let!(:session) do
      create_run_and_session(run:).last.tap do |session|
        session.update!(capability_token_digest: Digest::SHA256.hexdigest(token))
      end
    end
    let(:runner) { instance_double(Orchestrator::Runner::Local, verify_job_finished!: true) }

    before do
      host! "127.0.0.1"
      allow(Orchestrator::Runner).to receive(:for).with(run.workspace).and_return(runner)
    end

    def call_finish(meta: nil, arguments: { summary: "Explicit end requested; merged" })
      params = { name: "job_finished", arguments: }
      params[:_meta] = meta if meta
      post "/mcp/run", params: JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/call", params:),
        headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json, text/event-stream",
          "HTTP_AUTHORIZATION" => "Bearer #{token}" }
      JSON.parse(response.body).fetch("result")
    end

    [ nil, { progressToken: "finish-1", "client/example" => { trace: "123" } } ].each do |meta|
      it "arms deferred shutdown on response close #{meta ? 'with metadata' : 'without metadata'}" do
        expect { expect(call_finish(meta:).dig("structuredContent", "finalization")).to eq("accepted") }
          .to have_enqueued_job(JobFinalizationJob).with(session.id).at(a_value_within(1).of(5.seconds.from_now))
        expect(session.reload.finalization_ready_at).to be_present
        expect(session).to be_live
        expect(run.checkpoints.count).to eq(1)
      end
    end

    it "does not arm shutdown when metadata-bearing Git verification fails" do
      allow(runner).to receive(:verify_job_finished!).and_raise(Orchestrator::Runner::Error, "uncommitted work")
      expect { expect(call_finish(meta: { progressToken: 1 })["isError"]).to be(true) }
        .not_to have_enqueued_job(JobFinalizationJob)
      expect(session.reload.finalization_requested_at).to be_nil
      expect(session.finalization_ready_at).to be_nil
      expect(session).to be_live
      expect(run.checkpoints.count).to eq(0)
    end

    it "keeps accepted but unarmed requests open across restart until a live-token retry is acknowledged" do
      Orchestrator::JobFinalization.request!(session, summary: "Original final report")
      session.update!(finalization_requested_at: 1.hour.ago)
      expect { Orchestrator::JobFinalization.recover }.not_to have_enqueued_job(JobFinalizationJob)
      JobFinalizationJob.perform_now(session.id)
      expect(session.reload).to be_live
      expect(session.finalization_ready_at).to be_nil

      expect { expect(call_finish(meta: { progressToken: "invalid" }, arguments: {})["isError"]).to be(true) }
        .not_to have_enqueued_job(JobFinalizationJob)
      expect(session.reload.finalization_ready_at).to be_nil

      expect { call_finish(meta: { progressToken: "retry" }) }.to have_enqueued_job(JobFinalizationJob).with(session.id)
      ready_at = session.reload.finalization_ready_at
      call_finish(meta: { progressToken: "retry-again" })
      expect(session.reload.finalization_ready_at).to eq(ready_at)
      expect(run.checkpoints.pluck(:summary)).to eq([ "Original final report" ])
      session.update!(finalization_ready_at: 1.minute.ago)
      expect { Orchestrator::JobFinalization.recover }.to have_enqueued_job(JobFinalizationJob).with(session.id)
    end
  end
end

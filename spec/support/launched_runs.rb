# Launching real runs in a request spec, the way the operator does: queue_run
# over /mcp/admin, RunDispatchJob and StartRunSessionJob provisioning a real
# worktree, and RunSessionRunner.start! driving the fake herdr (tag the
# example :fake_herdr). Shared by the lifecycle and remote-control specs.
RSpec.shared_context "launched runs" do
  before do
    # Where every real client reaches it; the MCP transport's DNS-rebinding
    # check turns away the request-spec default of www.example.com.
    host! "127.0.0.1"
    stub_const("Orchestrator::RunSessionRunner::SHELL_POLL_INTERVAL_SECONDS", 0.01)
    stub_const("Orchestrator::RunSessionRunner::AGENT_DETECT_POLL_INTERVAL_SECONDS", 0.05)
    stub_const("Orchestrator::RunSessionRunner::READY_POLL_INTERVAL_SECONDS", 0.05)
    stub_const("Orchestrator::RunSessionRunner::PID_POLL_INTERVAL_SECONDS", 0.05)
    stub_const("Orchestrator::RunSessionRunner::PROMPT_SUBMIT_POLL_INTERVAL_SECONDS", 0.05)
  end

  let(:workspace) { create_workspace(root_path: create_source_checkout) }

  # The Streamable HTTP handshake a real MCP client performs, then one call.
  def mcp_call(path, tool, token: nil, **arguments)
    headers = { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json, text/event-stream" }
    headers["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
    post path, headers:, params: JSON.generate(
      jsonrpc: "2.0", id: 1, method: "initialize",
      params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "spec", version: "1" } }
    )
    expect(response).to have_http_status(:ok)
    headers["HTTP_MCP_SESSION_ID"] = response.headers["mcp-session-id"]
    post path, headers:, params: JSON.generate(jsonrpc: "2.0", method: "notifications/initialized")
    post path, headers:, params: JSON.generate(jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: tool, arguments: })
    body = response.body
    body = body.lines.find { |line| line.start_with?("data:") }.delete_prefix("data:") if body.start_with?("event:", "data:")
    result = JSON.parse(body).fetch("result")
    expect(result["isError"]).to be_falsey, result.to_s
    result.fetch("structuredContent")
  end

  def queue_and_launch(task)
    run_id = nil
    perform_enqueued_jobs(only: [ RunDispatchJob, StartRunSessionJob ]) do
      run_id = mcp_call("/mcp/admin", "queue_run", task:, workspace: workspace.name).fetch("runId")
    end
    Run.find_by!(run_id:)
  end

  def session_token(run = nil)
    creates = fake_herdr.requests_for("workspace.create")
    create = run ? creates.find { |request| request.dig("env", "WORKFLOW_RUN_ID") == run.run_id } : creates.last
    create.dig("env", "WORKFLOW_RUN_TOKEN")
  end

  # The session's own report_idle, over /mcp/run with its capability.
  def report(run, outcome, summary)
    mcp_call("/mcp/run", "report_idle", token: session_token(run), outcome:, summary:)
  end

  def wait_for(timeout: 5)
    deadline = Time.current + timeout
    until (value = yield)
      raise "timed out waiting" if Time.current > deadline

      sleep 0.05
    end
    value
  end
end

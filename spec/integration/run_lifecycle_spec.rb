require "rails_helper"

# A run's whole life, end to end, with nothing stubbed but the model: queue
# through /mcp/admin, RunDispatchJob, StartRunSessionJob provisioning a real
# git worktree, RunSessionRunner.start! driving a (fake) herdr over its real
# socket until a real agent process is running, report_idle through /mcp/run
# with the capability the session was launched with, the operator's message
# box, RunSessionReconcileJob, Close session and WorktreeJanitor.
#
# The agent is FakeHerdr::Agent in "manual" mode: it becomes ready and takes
# the prompt, and the spec reports on its behalf. bin/sandbox verify runs the
# same lifecycle out of process, with the agent reporting over real HTTP.
RSpec.describe "a run's lifecycle", type: :request do
  before do
    # Where every real client reaches it; the MCP transport's DNS-rebinding
    # check turns away the request-spec default of www.example.com.
    host! "127.0.0.1"
    stub_const("Orchestrator::Runner::SessionLauncher::SHELL_POLL_INTERVAL_SECONDS", 0.01)
    stub_const("Orchestrator::Runner::SessionLauncher::AGENT_DETECT_POLL_INTERVAL_SECONDS", 0.05)
    stub_const("Orchestrator::Runner::SessionLauncher::READY_POLL_INTERVAL_SECONDS", 0.05)
    stub_const("Orchestrator::Runner::SessionLauncher::PID_POLL_INTERVAL_SECONDS", 0.05)
    stub_const("Orchestrator::Runner::SessionLauncher::PROMPT_SUBMIT_POLL_INTERVAL_SECONDS", 0.05)
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

  def session_token
    fake_herdr.requests_for("workspace.create").last.dig("env", "WORKFLOW_RUN_TOKEN")
  end

  def wait_for(timeout: 5)
    deadline = Time.current + timeout
    until (value = yield)
      raise "timed out waiting" if Time.current > deadline

      sleep 0.05
    end
    value
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  it "queues, launches, reports, takes a message, and is closed with its worktree reclaimed", :fake_herdr do
    run = queue_and_launch("Exercise the lifecycle")
    session = run.live_session

    expect(run).to have_attributes(status: "running", branch_name: start_with("workflow/"))
    expect(File.directory?(run.target_root)).to be(true)
    expect(session).to have_attributes(status: "running", herdr_pane_id: "w1:p1")
    expect(process_alive?(session.pid)).to be(true)
    create = fake_herdr.requests_for("workspace.create").last
    expect(create).to include("cwd" => run.target_root, "focus" => false)
    expect(create["env"]).to include("WORKFLOW_RUN_ID" => run.run_id)
    expect(fake_herdr.requests_for("agent.start").last).to include("kind" => "claude", "pane_id" => "w1:p1")
    expect(fake_herdr.requests_for("agent.prompt").last["text"]).to include("# Task", "Exercise the lifecycle")

    report = mcp_call("/mcp/run", "report_idle", token: session_token, outcome: "done", summary: "## Did it")
    expect(report).to include("outcome" => "done", "status" => "awaiting_review")
    expect(run.reload.checkpoints.map(&:summary)).to eq([ "## Did it" ])

    # An idle session is not an anomaly: reconcile only refreshes it.
    RunSessionReconcileJob.perform_now
    expect(session.reload).to be_live
    expect(session.cli_session_id).to start_with("fake-")

    post send_message_workspace_run_path(workspace, run), params: { message: "one more thing" }
    expect(fake_herdr.requests_for("agent.prompt").last["text"]).to eq("one more thing")
    expect(wait_for { fake_herdr.pane("w1:p1")[:transcript].scan("received a").size == 2 }).to be(true)

    expect { post close_session_workspace_run_path(workspace, run) }.to have_enqueued_job(RunDispatchJob)

    expect(flash[:notice]).to include("removed #{run.worktree_name}")
    expect(run.reload.status).to eq("completed")
    expect(session.reload).to have_attributes(outcome: "done", herdr_pane_id: nil)
    expect(session).to be_ended
    expect(fake_herdr.workspace_ids).to be_empty
    expect(wait_for { !process_alive?(session.pid) }).to be(true)
    expect(File.directory?(run.target_root)).to be(false)
    expect(Orchestrator::RunConcurrency.in_flight).to eq(0)
  end

  it "keeps a worktree with uncommitted work when the session is closed", :fake_herdr do
    run = queue_and_launch("Leave something behind")
    mcp_call("/mcp/run", "report_idle", token: session_token, outcome: "done", summary: "Left a file")
    File.write(File.join(run.target_root, "notes.md"), "uncommitted\n")

    post close_session_workspace_run_path(workspace, run)

    expect(flash[:notice]).to include("Kept #{run.worktree_name}")
    expect(run.reload).to be_kept_worktree
  end

  it "fails the run and frees its slot when the CLI dies without reporting", :fake_herdr do
    run = queue_and_launch("Crash")
    session = run.live_session

    Process.kill("KILL", -session.pid)
    wait_for { !process_alive?(session.pid) }
    RunSessionReconcileJob.perform_now

    expect(run.reload.status).to eq("failed")
    expect(session.reload).to have_attributes(outcome: "failed", result: include("exited without reporting"))
    expect(fake_herdr.workspace_ids).to be_empty
    expect(File.directory?(run.target_root)).to be(false)
    expect(Orchestrator::RunConcurrency.in_flight).to eq(0)
  end

  it "completes a run whose herdr workspace the operator closed by hand after it reported done", :fake_herdr do
    run = queue_and_launch("Close me by hand")
    mcp_call("/mcp/run", "report_idle", token: session_token, outcome: "done", summary: "Done")

    fake_herdr.close_workspace!(run.live_session.herdr_workspace_id)
    RunSessionReconcileJob.perform_now

    expect(run.reload.status).to eq("completed")
    expect(File.directory?(run.target_root)).to be(false)
  end

  it "fails the launch, keeps the pane's last screen, and frees the slot when the CLI never starts",
    :fake_herdr, fake_agent_command: [ "sh", "-c", "echo 'claude: command not found'; exit 127" ] do
    stub_const("Orchestrator::Runner::SessionLauncher::AGENT_DETECT_POLL_ATTEMPTS", 4)

    run_id = nil
    perform_enqueued_jobs(only: RunDispatchJob) do
      run_id = mcp_call("/mcp/admin", "queue_run", task: "Never starts", workspace: workspace.name).fetch("runId")
    end
    run = Run.find_by!(run_id:)
    expect { StartRunSessionJob.perform_now(run.id) }.to raise_error(Orchestrator::Runner::LaunchError, /never detected/)

    expect(run.reload).to have_attributes(status: "failed", launch_error: include("never detected claude"))
    expect(run.latest_session.result).to include("claude: command not found")
    expect(fake_herdr.workspace_ids).to be_empty
    expect(Orchestrator::RunConcurrency.in_flight).to eq(0)
  end
end

require "rails_helper"

# A run on a remote runner, end to end, with two machines' worth of runner
# on this one: the orchestrator here (this process, its own fake herdr, the
# :fake_herdr tag), and a real runner-only process (bin/runner) as the other
# machine, with its own fake herdr and its own clone of the repository. The
# runner registers over /mcp/admin, the run launches through it over HTTP,
# the session's MCP config points at the orchestrator's tailnet URL, it
# reports through /mcp/run, reconcile rides out the runner going away, and
# Close session has the janitor remove the worktree over there.
#
# queue_run cannot choose a runner yet (phase 3), so the run is created
# directly on the remote one.
RSpec.describe "a run on a remote runner", type: :request do
  include_context "launched runs"

  let(:remote_root) { Dir.mktmpdir("other-machine") }

  around do |example|
    @remote_herdr = FakeHerdr::Server.new(
      socket_path: File.join(remote_root, "herdr.sock"),
      # Busy long enough for the runner's real prompt-pickup check (four
      # samples half a second apart: SessionLauncher), which the spec's
      # shortened intervals do not reach in another process.
      agent_env: { "FAKE_AGENT_MODE" => "manual", "FAKE_AGENT_WORK_SECONDS" => "3" }
    ).start
    @runner_process = RunnerProcess.new(herdr_socket: @remote_herdr.socket_path, root: File.join(remote_root, "runner")).start
    example.run
  ensure
    @runner_process&.stop
    @remote_herdr&.stop
    FileUtils.rm_rf(remote_root)
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  # The other machine's own checkout of the workspace's repository.
  def clone_there
    there = File.join(remote_root, "src", "repo")
    system("git", "clone", "-q", workspace.repository_path, there, exception: true)
    system("git", "-C", there, "remote", "set-url", "origin", "https://example.test/paneyard.git", exception: true)
    there
  end

  it "launches on the other machine, reports to the orchestrator, survives a blip, and is closed and reclaimed there", :fake_herdr do
    there = clone_there
    registered = mcp_call("/mcp/admin", "register_runner", name: "mac", url: @runner_process.url,
      orchestratorUrl: "http://box.tailnet.test:7263", checkouts: [ { workspace: workspace.name, path: there } ])
    expect(registered).to include("checkouts" => [ { "workspace" => workspace.name, "repositoryPath" => there } ], "problems" => [])
    mac = RegisteredRunner.find_by!(name: "mac")

    run = create_run(workspace:, runner: mac, status: "queued", base_branch: "main", target_root: there,
      task: "Exercise a remote run")
    perform_enqueued_jobs(only: [ RunDispatchJob, StartRunSessionJob ]) { RunDispatchJob.perform_later }
    run.reload
    session = run.live_session

    expect(run).to have_attributes(status: "running", source_root: there, branch_name: start_with("paneyard/"))
    expect(run.target_root).to start_with(remote_root)
    expect(File.directory?(run.target_root)).to be(true)
    expect(session).to have_attributes(status: "running", herdr_pane_id: "w1:p1")
    expect(process_alive?(session.pid)).to be(true)
    expect(session.lost_prompts).to eq([])
    # Everything happened in the other machine's herdr, none of it here.
    expect(@remote_herdr.requests_for("worktree.create").last).to include("cwd" => there, "branch" => run.branch_name, "base" => "main")
    expect(@remote_herdr.requests_for("agent.prompt").last["text"]).to include("Exercise a remote run")
    expect(fake_herdr.requests).to be_empty
    # Its runtime files are the runner's, and its MCP config sends reports
    # straight to the orchestrator's tailnet name, not to loopback.
    expect(session.mcp_config_path).to start_with(@runner_process.runtime_dir)
    expect(JSON.parse(File.read(session.mcp_config_path)).dig("mcpServers", "paneyard", "url"))
      .to eq("http://box.tailnet.test:7263/mcp/run")

    report = report(run, "done", "## Did it over there")
    expect(report).to include("outcome" => "done", "status" => "awaiting_review")

    RunSessionReconcileJob.perform_now
    expect(session.reload).to be_live
    expect(session.cli_session_id).to start_with("fake-")

    Orchestrator::RunSessionRunner.prompt!(session, "one more thing")
    expect(@remote_herdr.requests_for("agent.prompt").last["text"]).to eq("one more thing")

    # The runner going away says nothing about its sessions.
    @runner_process.stop
    RunSessionReconcileJob.perform_now
    expect(session.reload).to be_live
    expect(run.reload.status).to eq("awaiting_review")
    @runner_process = RunnerProcess.new(herdr_socket: @remote_herdr.socket_path, root: @runner_process.root,
      port: @runner_process.port).start

    Orchestrator::SessionClose.call(run)

    expect(run.reload.status).to eq("completed")
    expect(session.reload).to have_attributes(outcome: "done", herdr_pane_id: nil)
    expect(session.last_screen).to include("one more thing")
    expect(@remote_herdr.workspace_ids).to be_empty
    expect(wait_for { !process_alive?(session.pid) }).to be(true)
    expect(File.directory?(run.target_root)).to be(false)
    expect(Orchestrator::RunConcurrency.in_flight).to eq(0)
    expect(fake_herdr.requests).to be_empty

    # The janitor's sweep reaches the remote runner too, and finds nothing left.
    expect { WorktreeCleanupJob.perform_now }.not_to raise_error
  end
end

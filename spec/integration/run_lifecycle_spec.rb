require "rails_helper"
require "open3"

# A run's whole life, end to end, with nothing stubbed but the model: queue
# through /mcp/admin, RunDispatchJob, StartRunSessionJob having (fake) herdr
# make a real git worktree, RunSessionRunner.start! driving that herdr over its real
# socket until a real agent process is running, report_idle through /mcp/run
# with the capability the session was launched with, operator steering,
# RunSessionReconcileJob, SessionClose and WorktreeJanitor.
#
# The agent is FakeHerdr::Agent in "manual" mode: it becomes ready and takes
# the prompt, and the spec reports on its behalf. bin/sandbox verify runs the
# same lifecycle out of process, with the agent reporting over real HTTP.
RSpec.describe "a run's lifecycle", type: :request do
  include_context "launched runs"

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  it "queues, launches, reports, takes a message, and is closed with its worktree reclaimed", :fake_herdr do
    run = queue_and_launch("Exercise the lifecycle")
    session = run.live_session

    expect(run).to have_attributes(status: "running", branch_name: start_with("paneyard/"))
    expect(File.directory?(run.target_root)).to be(true)
    expect(session).to have_attributes(status: "running", herdr_pane_id: "w1:p1")
    expect(process_alive?(session.pid)).to be(true)
    create = fake_herdr.requests_for("worktree.create").last
    expect(create).to eq("cwd" => workspace.repository_path, "branch" => run.branch_name, "base" => "main",
                         "label" => run.worktree_name, "focus" => false)
    expect(run.target_root).not_to start_with(workspace.repository_path)
    expect(fake_herdr.requests_for("workspace.create")).to be_empty
    # No pane is given an environment of its own.
    expect(fake_herdr.requests.map(&:last)).to all(satisfy { |params| !params.key?("env") })
    expect(fake_herdr.requests_for("agent.start").last).to include("kind" => "claude", "pane_id" => "w1:p1")
    expect(fake_herdr.requests_for("agent.prompt").last["text"]).to include("# Task", "Exercise the lifecycle")

    report = mcp_call("/mcp/run", "report_idle", token: session_token, outcome: "done", summary: "## Did it")
    expect(report).to include("outcome" => "done", "status" => "awaiting_review")
    expect(run.reload.checkpoints.map(&:summary)).to eq([ "## Did it" ])

    # An idle session is not an anomaly: reconcile only refreshes it.
    RunSessionReconcileJob.perform_now
    expect(session.reload).to be_live
    expect(session.cli_session_id).to start_with("fake-")

    Orchestrator::RunSessionRunner.prompt!(session, "one more thing")
    expect(fake_herdr.requests_for("agent.prompt").last["text"]).to eq("one more thing")
    expect(wait_for { fake_herdr.pane("w1:p1")[:transcript].scan("received a").size == 2 }).to be(true)

    expect { Orchestrator::SessionClose.call(run) }.to have_enqueued_job(RunDispatchJob)

    expect(run.reload.status).to eq("completed")
    expect(session.reload).to have_attributes(outcome: "done", herdr_pane_id: nil)
    expect(session).to be_ended
    expect(fake_herdr.workspace_ids).to be_empty
    expect(wait_for { !process_alive?(session.pid) }).to be(true)
    expect(File.directory?(run.target_root)).to be(false)
    expect(Orchestrator::RunConcurrency.in_flight).to eq(0)
  end

  # run-20260929-191533-d44e: the prompt was typed into claude's input box but
  # never submitted, after herdr briefly reported the agent non-idle.
  it "submits a prompt the agent left unsubmitted after a flicker of activity", :fake_herdr do
    run = queue_and_launch("Stuck in the input box [fake-agent-prompt: unsubmitted]")

    expect(run.reload.live_session).to have_attributes(status: "running")
    expect(fake_herdr.requests_for("agent.send_keys").last).to include("target" => "w1:p1", "keys" => [ "Enter" ])
    transcript = -> { fake_herdr.pane("w1:p1")[:transcript] }
    expect(wait_for { transcript.call.include?("received a") }).to be(true)
    expect(transcript.call.index("left a")).to be < transcript.call.index("received a")
  end

  it "keeps a worktree with uncommitted work when the session is closed", :fake_herdr do
    run = queue_and_launch("Leave something behind")
    mcp_call("/mcp/run", "report_idle", token: session_token, outcome: "done", summary: "Left a file")
    File.write(File.join(run.target_root, "notes.md"), "uncommitted\n")

    closed = Orchestrator::SessionClose.call(run)

    expect(closed[:worktree]).to eq("kept")
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

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir.to_s, *args)
    raise out unless status.success?

    out.strip
  end

  def commit_in(dir, file, message)
    File.write(File.join(dir, file), "#{message}\n")
    git(dir, "add", file)
    git(dir, "-c", "user.email=agent@example.test", "-c", "user.name=Agent", "commit", "-qm", message)
  end

  describe "base branches" do
    let(:workspace) { create_workspace(repository_path: create_source_checkout(branches: [ "feature/payments" ])) }

    def queue(task, **arguments)
      run_id = nil
      perform_enqueued_jobs(only: [ RunDispatchJob, StartRunSessionJob ]) do
        run_id = mcp_call("/mcp/admin", "queue_run", task:, workspace: workspace.name, **arguments).fetch("runId")
      end
      Run.find_by!(run_id:)
    end

    it "runs two sessions from different base branches of one workspace at once", :fake_herdr do
      git(workspace.repository_path, "switch", "-q", "-c", "operator-wip")

      from_main = queue("From main")
      from_payments = queue("From payments", baseBranch: "feature/payments")

      expect([ from_main, from_payments ].map(&:reload).map(&:status)).to eq(%w[running running])
      expect(from_main.base_branch).to eq("main")
      expect(from_payments.base_branch).to eq("feature/payments")
      expect(git(from_main.target_root, "rev-parse", "HEAD")).to eq(git(workspace.repository_path, "rev-parse", "main"))
      expect(git(from_payments.target_root, "rev-parse", "HEAD")).to eq(git(workspace.repository_path, "rev-parse", "feature/payments"))
      expect(fake_herdr.requests_for("worktree.create").map { |request| request["base"] }).to eq(%w[main feature/payments])
      # The operator's checkout is left exactly as it was.
      expect(git(workspace.repository_path, "branch", "--show-current")).to eq("operator-wip")
      expect(fake_herdr.requests_for("agent.prompt").last["text"]).to include("from `feature/payments`", "into `feature/payments`")
    end

    it "refuses a base branch the repository does not have, queueing nothing", :fake_herdr do
      result = McpTools::QueueRunTool.call(task: "Nope", workspace: workspace.name, baseBranch: "feature/missing", server_context: {})

      expect(result.error?).to be(true)
      expect(result.content.first[:text]).to include("no local branch `feature/missing`")
      expect(workspace.runs.count).to eq(0)
      expect(fake_herdr.requests_for("worktree.create")).to be_empty
    end

    it "removes the worktree once its work is merged into its own base branch, not main", :fake_herdr do
      run = queue("Payments fix", baseBranch: "feature/payments")
      mcp_call("/mcp/run", "report_idle", token: session_token(run), outcome: "done", summary: "Fixed")
      commit_in(run.target_root, "fix.txt", "Fix payments")
      # The merge the prompt describes: feature/payments is checked out nowhere,
      # so it fast-forwards without touching any checkout.
      git(workspace.repository_path, "fetch", "-q", ".", "#{run.branch_name}:feature/payments")
      expect(system("git", "-C", workspace.repository_path, "merge-base", "--is-ancestor", run.branch_name, "main")).to be(false)

      closed = Orchestrator::SessionClose.call(run)

      expect(closed[:worktree]).to eq("removed")
      expect(File.directory?(run.target_root)).to be(false)
      expect(git(workspace.repository_path, "branch", "--list", run.branch_name)).to include(run.branch_name)
      expect(fake_herdr.requests_for("worktree.remove").size).to eq(1)
    end

    it "keeps a worktree whose commits are in main but not in its own base branch", :fake_herdr do
      run = queue("Payments fix", baseBranch: "feature/payments")
      mcp_call("/mcp/run", "report_idle", token: session_token(run), outcome: "done", summary: "Fixed")
      commit_in(run.target_root, "fix.txt", "Fix payments")
      git(workspace.repository_path, "merge", "-q", "--ff-only", run.branch_name)

      closed = Orchestrator::SessionClose.call(run)

      expect(closed[:worktree]).to eq("kept")
      expect(run.reload).to be_kept_worktree
    end

    it "never reclaims worktrees that are not a run's, or the operator's checkout", :fake_herdr do
      run = queue("A run")
      mcp_call("/mcp/run", "report_idle", token: session_token(run), outcome: "done", summary: "Done")
      operators = File.join(File.dirname(workspace.repository_path), "operators-own")
      git(workspace.repository_path, "worktree", "add", "-q", "-b", "operator/own", operators, "main")
      Orchestrator::SessionClose.call(run)

      expect(Orchestrator::WorktreeJanitor.sweep(workspace)).to eq(0)

      expect(File.directory?(operators)).to be(true)
      expect(File.exist?(File.join(workspace.repository_path, "README.md"))).to be(true)
      expect(git(workspace.repository_path, "worktree", "list")).to include("operators-own")
      expect(fake_herdr.requests_for("worktree.open").map { |request| request["path"] }).to all(eq(run.target_root))
    end
  end
end

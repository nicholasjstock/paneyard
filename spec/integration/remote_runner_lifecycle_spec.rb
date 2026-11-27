require "rails_helper"
require "open3"

# A run on a remote runner, end to end, with two machines' worth of runner
# on this one: the orchestrator here (this process, its own fake herdr, the
# :fake_herdr tag), and a real runner-only process (bin/runner) as the other
# machine, with its own fake herdr and its own clone of the repository. The
# runner registers over /mcp/admin, the run launches through it over HTTP,
# the session's MCP config points at the orchestrator's tailnet URL, it
# reports through /mcp/run, reconcile rides out the runner going away, and
# Close session has the janitor remove the worktree over there.
#
# The run is created directly on the remote one. The second example has the
# other machine clone a workspace it has no checkout of when a run launches
# there (Orchestrator::WorkspaceCheckout), and registers a repository only it
# has. The third moves a run between the two machines with move_run
# (Orchestrator::RunMove): its commits, uncommitted changes, untracked files
# and transcripts go over and back, through the orchestrator.
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

  it "clones a workspace the other machine has no checkout of when a run launches there, and registers one only it has", :fake_herdr do
    projects = File.join(remote_root, "Source")
    registered = mcp_call("/mcp/admin", "register_runner", name: "mac", url: @runner_process.url,
      orchestratorUrl: "http://box.tailnet.test:7263", projectsDir: projects)
    expect(registered).to include("projectsDir" => projects, "checkouts" => [])
    # The origin the other machine clones, readable from there.
    workspace.update!(origin_url: workspace.repository_path)

    queued = mcp_call("/mcp/admin", "queue_run", task: "Exercise a clone", workspace: workspace.name, runner: "mac")
    expect(queued).to include("runner" => "mac", "clonesAtLaunch" => true)
    run = Run.find_by!(run_id: queued.fetch("runId"))
    perform_enqueued_jobs(only: [ RunDispatchJob, StartRunSessionJob ]) { RunDispatchJob.perform_later }
    run.reload
    clone = File.join(projects, workspace.name)
    expect(run).to have_attributes(status: "running", source_root: clone, launch_error: nil)
    expect(git(clone, "rev-parse", "HEAD")).to eq(git(workspace.repository_path, "rev-parse", "main"))
    expect(run.target_root).to start_with(remote_root)
    expect(workspace.repository_path_for(RegisteredRunner.find_by!(name: "mac"))).to eq(clone)
    expect(@remote_herdr.requests_for("worktree.create").last).to include("cwd" => clone, "base" => "main")
    expect(fake_herdr.requests).to be_empty
    report(run, "done", "## Cloned and done")
    Orchestrator::SessionClose.call(run)
    expect(File.directory?(clone)).to be(true)

    # A repository that is only on that machine registers there, and only
    # that checkout is recorded.
    only_there = File.join(remote_root, "only-there")
    system("git", "clone", "-q", workspace.repository_path, only_there, exception: true)
    system("git", "-C", only_there, "remote", "set-url", "origin", "https://example.test/only-there.git", exception: true)

    added = mcp_call("/mcp/admin", "register_workspace", path: only_there, runner: "mac")

    expect(added).to include("name" => "only-there", "repositoryPath" => nil, "originUrl" => "https://example.test/only-there.git")
    expect(added["runners"]).to include({ "name" => "mac", "kind" => "remote", "repositoryPath" => only_there, "checkedOut" => true })
    expect(Workspace.find_by!(name: "only-there").checkouts.map { |checkout| checkout.runner.name }).to eq([ "mac" ])
    defaulted = mcp_call("/mcp/admin", "queue_run", task: "Over there by default", workspace: "only-there")
    expect(defaulted).to include("runner" => "mac")
    expect(defaulted).not_to have_key("clonesAtLaunch")
  end

  def git(dir, *args)
    output, error, status = Open3.capture3("git", "-C", dir.to_s, *args)
    raise "git #{args.join(' ')} failed in #{dir}: #{error}" unless status.success?

    output
  end

  def claude_project(config_dir, cwd)
    File.join(config_dir, "projects", File.realpath(cwd).gsub(/[^A-Za-z0-9]/, "-"))
  end

  it "moves a run with its uncommitted work to the other machine and reopens it there, then back again", :fake_herdr do
    there = clone_there
    mcp_call("/mcp/admin", "register_runner", name: "mac", url: @runner_process.url,
      orchestratorUrl: "http://box.tailnet.test:7263", checkouts: [ { workspace: workspace.name, path: there } ])
    run = queue_and_launch("Exercise a move")
    here = run.target_root
    expect(run.runner).to eq(RegisteredRunner.local)
    # The session's work so far: a commit, a staged and an unstaged change,
    # an untracked file, and a conversation the CLI kept for this worktree.
    git(here, "config", "user.email", "agent@example.test")
    git(here, "config", "user.name", "Agent")
    File.write(File.join(here, "feature.rb"), "feature\n")
    git(here, "add", "feature.rb")
    git(here, "commit", "-q", "-m", "Add feature")
    File.write(File.join(here, "README.md"), "staged\n")
    git(here, "add", "README.md")
    File.write(File.join(here, "feature.rb"), "feature, unfinished\n")
    File.write(File.join(here, "notes.md"), "untracked notes\n")
    project_here = claude_project(File.join(TRANSCRIPT_SOURCES_ROOT, "claude"), here)
    FileUtils.mkdir_p(project_here)
    File.write(File.join(project_here, "conv-1.jsonl"), "#{JSON.generate('type' => 'user', 'cwd' => here)}\n")
    report(run, "done", "## Halfway there")
    commits = git(here, "rev-parse", "HEAD")

    moved = mcp_call("/mcp/admin", "move_run", workspace: workspace.name, runId: run.run_id, toRunner: "mac")

    run.reload
    expect(moved).to include("from" => "local", "runner" => "mac", "status" => "queued", "reopened" => "kept",
      "closed" => { "outcome" => "done", "worktree" => "kept" })
    expect(moved["sourceWorktree"]).to eq("path" => here, "state" => "kept")
    expect(moved["transferred"]).to include("changedFiles" => contain_exactly("README.md", "feature.rb"),
      "untrackedFiles" => [ "notes.md" ], "staged" => true, "transcripts" => [ "claude/conv-1.jsonl" ])
    expect(run.runner.name).to eq("mac")
    expect(run.target_root).to start_with(remote_root)
    expect(run.source_root).to eq(there)
    # The work is over there, uncommitted as it was; and still here.
    gone = run.target_root
    expect(git(gone, "rev-parse", "HEAD")).to eq(commits)
    expect(git(gone, "diff", "--cached", "--name-only").split).to eq([ "README.md" ])
    expect(File.read(File.join(gone, "feature.rb"))).to eq("feature, unfinished\n")
    expect(File.read(File.join(gone, "notes.md"))).to eq("untracked notes\n")
    expect(File.read(File.join(here, "notes.md"))).to eq("untracked notes\n")
    expect(git(there, "rev-parse", "refs/heads/#{run.branch_name}")).to eq(commits)
    # The transcript is where claude over there looks for the new worktree.
    placed = File.join(claude_project(File.join(@runner_process.root, "home", ".claude"), gone), "conv-1.jsonl")
    expect(JSON.parse(File.read(placed))["cwd"]).to eq(gone)
    expect(get_run = mcp_call("/mcp/admin", "get_run", workspace: workspace.name, runId: run.run_id))
      .to include("runner" => "mac", "moves" => [ include("from" => "local", "to" => "mac", "leftBehind" => here, "leftBehindState" => "kept") ])
    # Queued again over there: not movable until its session is up.
    expect(get_run).not_to have_key("moveTo")

    perform_enqueued_jobs(only: [ RunDispatchJob, StartRunSessionJob ]) { RunDispatchJob.perform_later }
    session = run.reload.live_session
    expect(session).to have_attributes(status: "running")
    expect(@remote_herdr.requests_for("worktree.open").last).to include("path" => gone)
    prompt = @remote_herdr.requests_for("agent.prompt").last["text"]
    expect(prompt).to include("# Reopened", "## Halfway there", "moved this run from runner `local` to `mac`")
    expect(JSON.parse(File.read(session.mcp_config_path)).dig("mcpServers", "paneyard", "url")).to eq("http://box.tailnet.test:7263/mcp/run")

    # More work over there, then back to this machine, where the worktree it
    # left is still exactly as it was carried away.
    File.write(File.join(gone, "notes.md"), "untracked notes, longer\n")
    report(run, "done", "## Done over there")
    expect(mcp_call("/mcp/admin", "get_run", workspace: workspace.name, runId: run.run_id)["moveTo"]).to eq([ "local" ])

    back = mcp_call("/mcp/admin", "move_run", workspace: workspace.name, runId: run.run_id, toRunner: "local")

    run.reload
    expect(back).to include("from" => "mac", "runner" => "local", "reopened" => "kept")
    expect(back["sourceWorktree"]).to include("path" => gone, "state" => "kept")
    expect(run.target_root).to eq(here)
    expect(File.read(File.join(here, "notes.md"))).to eq("untracked notes, longer\n")
    expect(git(here, "diff", "--cached", "--name-only").split).to eq([ "README.md" ])
    expect(run.moves.map(&:source_worktree)).to eq(%w[reused kept])

    # The janitor keeps what holds work, on both machines.
    WorktreeCleanupJob.perform_now
    expect(File.directory?(gone)).to be(true)
    expect(File.directory?(here)).to be(true)
  ensure
    FileUtils.rm_rf(project_here) if project_here
  end
end

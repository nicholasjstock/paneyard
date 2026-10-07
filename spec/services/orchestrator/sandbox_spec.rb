require "rails_helper"
require "open3"

# A sandbox instance can boot against a copy of production's database, full
# of real workspace paths and real session pids. These are the lines that
# keep it from acting on any of them.
RSpec.describe Orchestrator::Sandbox do
  let(:sandbox_root) { Dir.mktmpdir("sandbox-root") }

  # Fixtures are created first, as the real instance would have: the point is
  # what a sandbox does with records it did not create.
  def sandbox_on!
    ENV["PANEYARD_SANDBOX"] = "1"
  end

  around do |example|
    ENV["PANEYARD_SANDBOX_ROOT"] = sandbox_root
    example.run
  ensure
    ENV.delete("PANEYARD_SANDBOX")
    ENV.delete("PANEYARD_SANDBOX_ROOT")
  end

  it "ignores an inherited HERDR_SOCKET_PATH and only talks to its own fake herdr" do
    original = ENV["HERDR_SOCKET_PATH"]
    ENV["HERDR_SOCKET_PATH"] = File.expand_path("~/.config/herdr/herdr.sock")
    sandbox_on!

    expect(Orchestrator::Runner::Herdr.socket_path).to eq(PaneyardSandbox.herdr_socket_path(sandbox_root))
    expect(Orchestrator::Runner::Herdr.socket_path).to start_with(Dir.tmpdir)
    expect(Orchestrator::Runner::Herdr.socket_path.bytesize).to be < 104
  ensure
    ENV["HERDR_SOCKET_PATH"] = original
  end

  it "only accepts workspaces inside the sandbox root" do
    sandbox_on!
    outside = Workspace.new(name: "real", repository_path: Dir.mktmpdir("real-project"))
    inside = Workspace.new(name: "scratch", repository_path: File.join(sandbox_root, "repos", "demo"))

    expect(outside).not_to be_valid
    expect(outside.errors[:repository_path].join).to include("inside the sandbox root")
    expect(inside).to be_valid
  end

  it "will not even look at a repository outside the sandbox when registering one" do
    repository = create_source_checkout
    sandbox_on!

    result = Orchestrator::WorkspaceRegistration.register(name: "real", path: repository).last

    expect(result["problems"].map { |problem| problem["code"] }).to eq(%w[outside_sandbox])
    expect(result["problems"].first["message"]).to match(/sandbox refuses to register a workspace at .* outside/)
    expect(Workspace.find_by(name: "real")).to be_nil
  end

  it "refuses to provision a worktree outside the sandbox, whatever the database says" do
    workspace = create_workspace(repository_path: create_source_checkout)
    run, session = create_run_and_session(run: create_run(workspace:, status: "launching"))
    sandbox_on!

    expect { Orchestrator::GitWorktree.provision!(run, session:) }.to raise_error(Orchestrator::Runner::Error, /sandbox refuses .* outside/)
    output, = Open3.capture2("git", "-C", workspace.repository_path, "worktree", "list")
    expect(output.lines.size).to eq(1)
  end

  it "never sweeps or releases worktrees of a workspace outside the sandbox" do
    workspace = create_workspace(repository_path: create_source_checkout)
    worktree = File.join(Dir.mktmpdir("outside-worktrees"), "done")
    system("git", "-C", workspace.repository_path, "worktree", "add", "-q", "-b", "paneyard/done", worktree, "main", exception: true)
    run = create_run(workspace:, status: "completed", worktree_name: "done", branch_name: "paneyard/done", target_root: worktree)
    sandbox_on!

    expect(Orchestrator::WorktreeJanitor.sweep_all).to eq(0)
    expect { Orchestrator::WorktreeJanitor.release!(run) }
      .to raise_error(Orchestrator::Runner::Error, /sandbox refuses/)
    expect(File.directory?(run.target_root)).to be(true)
  end

  it "refuses job finalization verification outside the sandbox before any Git or Herdr action" do
    repository = create_source_checkout
    sandbox_on!

    expect { Orchestrator::Runner.local.verify_job_finished!(repository_path: repository, path: repository, branch: "main", base_branch: "main") }
      .to raise_error(Orchestrator::Runner::Error, /sandbox refuses/)
  end

  it "allows push verification only for local remotes inside the sandbox" do
    sandbox_on!
    expect { described_class.guard_git_remote!(nil) }.to raise_error(described_class::Violation, /remote outside/)
    expect { described_class.guard_git_remote!(Dir.mktmpdir("outside-origin")) }.to raise_error(described_class::Violation)
    expect { described_class.guard_git_remote!(File.join(sandbox_root, "origin.git")) }.not_to raise_error
    ENV["PANEYARD_SANDBOX_REAL_HERDR"] = "1"
    expect { described_class.guard_git_remote!(nil) }.to raise_error(described_class::Violation)
  ensure
    ENV.delete("PANEYARD_SANDBOX_REAL_HERDR")
  end

  it "refuses a network push destination before contacting it during finalization" do
    repository = create_source_checkout
    worktree = File.join(File.dirname(repository), "run")
    system("git", "-C", repository, "worktree", "add", "-q", "-b", "paneyard/sandbox-push", worktree, "main", exception: true)
    system("git", "-C", worktree, "commit", "--allow-empty", "-qm", "Unmerged work", exception: true)
    ENV["PANEYARD_SANDBOX_ROOT"] = File.dirname(repository)
    sandbox_on!
    expect(Orchestrator::Runner::Worktrees).not_to receive(:remote_refs)

    expect { Orchestrator::Runner.local.verify_job_finished!(repository_path: repository, path: worktree, branch: "paneyard/sandbox-push", base_branch: "main") }
      .to raise_error(Orchestrator::Runner::Error, /sandbox refuses to verify a remote/)
    expect(File.directory?(worktree)).to be(true)
  end

  it "does not signal a session pid that is not one of its fake agents" do
    pid = Process.spawn("sleep", "30", pgroup: true)
    _run, session = create_run_and_session(pid:)
    sandbox_on!

    Orchestrator::RunSessionRunner.kill_process(session)

    expect(Process.kill(0, pid)).to eq(1)
  ensure
    Process.kill("KILL", -pid) rescue nil
    Process.wait(pid) rescue nil
  end

  describe "with real herdr opted back in (bin/sandbox start --real-herdr)" do
    around do |example|
      example.run
    ensure
      ENV.delete("PANEYARD_SANDBOX_REAL_HERDR")
    end

    it "uses the herdr socket it was given, and labels what it shows there as the sandbox's" do
      original = ENV["HERDR_SOCKET_PATH"]
      ENV["HERDR_SOCKET_PATH"] = "/tmp/operator-herdr.sock"
      sandbox_on!
      ENV["PANEYARD_SANDBOX_REAL_HERDR"] = "1"
      allow(Orchestrator::Runner::Herdr).to receive(:request!).and_return("root_pane" => {})
      allow(Orchestrator::Runner::Herdr).to receive(:request).and_return({})

      Orchestrator::Runner::Herdr.worktree_create(cwd: sandbox_root, branch: "paneyard/fix-it-1234", base: "main", label: "fix-it-1234")
      Orchestrator::Runner::Herdr.notify(title: "Run r1 done")

      expect(Orchestrator::Runner::Herdr.socket_path).to eq("/tmp/operator-herdr.sock")
      expect(Orchestrator::Runner::Herdr).to have_received(:request!)
        .with("worktree.create", hash_including(label: "[sandbox] fix-it-1234"))
      expect(Orchestrator::Runner::Herdr).to have_received(:request)
        .with("notification.show", hash_including(title: "[sandbox] Run r1 done"))
    ensure
      ENV["HERDR_SOCKET_PATH"] = original
    end

    it "signals only pids its own sessions recorded" do
      pid = Process.spawn("sleep", "30", pgroup: true)
      _run, session = create_run_and_session(pid:)
      sandbox_on!
      ENV["PANEYARD_SANDBOX_REAL_HERDR"] = "1"

      expect(described_class.allows_signal?(Process.pid)).to be(false)
      Orchestrator::RunSessionRunner.kill_process(session)

      Process.wait(pid)
      expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
    ensure
      Process.kill("KILL", -pid) rescue nil
    end

    it "keeps worktrees confined either way" do
      sandbox_on!
      ENV["PANEYARD_SANDBOX_REAL_HERDR"] = "1"
      expect(described_class.allows_path?(Dir.mktmpdir("real-project"))).to be(false)
    end
  end

  it "changes nothing when it is off" do
    expect(described_class.allows_path?("/anywhere")).to be(true)
    expect(described_class.allows_signal?(1)).to be(true)
    expect(Orchestrator::Runner::Herdr.socket_path).to end_with("specs-have-no-herdr.sock")
  end
end

RSpec.describe "the spec suite's own herdr guard" do
  it "points Orchestrator::Runner::Herdr at a socket that does not exist, so an unstubbed call cannot reach herdr" do
    expect(Orchestrator::Runner::Herdr.socket_path).to end_with("paneyard-specs-have-no-herdr.sock")
    expect(File.exist?(Orchestrator::Runner::Herdr.socket_path)).to be(false)
    expect { Orchestrator::Runner::Herdr.request!("workspace.get", workspace_id: "w1") }
      .to raise_error(Orchestrator::Runner::Herdr::Unreachable)
  end
end

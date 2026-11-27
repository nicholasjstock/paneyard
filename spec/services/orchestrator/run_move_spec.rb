require "rails_helper"
require "open3"

# Orchestrator::RunMove's own decisions: what it refuses, what it does
# before and after closing a session, and what it leaves behind. The other
# machine is a second Runner::Local in this process, on its own clone of the
# repository, so the git is real throughout; a real runner-only process is
# spec/integration/remote_runner_lifecycle_spec.rb's.
RSpec.describe Orchestrator::RunMove, type: :request do
  include_context "launched runs"

  let(:there_root) { Dir.mktmpdir("move-there") }
  let(:there) { File.join(there_root, "src", "repo") }
  let(:other_runtime) { File.join(there_root, "run_sessions") }
  let!(:mac) { RegisteredRunner.create!(name: "mac", kind: "remote", url: "http://mac.tailnet.test:3100") }
  let(:other) { Orchestrator::Runner::Local.new(runtime_root: other_runtime) }

  before do
    system("git", "clone", "-q", workspace.repository_path, there, exception: true)
    workspace.checkouts.create!(runner: mac, repository_path: there)
    allow(Orchestrator::Runner).to receive(:resolve).and_wrap_original do |original, record|
      record&.name == "mac" ? other : original.call(record)
    end
  end

  after { FileUtils.rm_rf(there_root) }

  def git(dir, *args)
    output, error, status = Open3.capture3("git", "-C", dir.to_s, *args)
    raise "git #{args.join(' ')} failed in #{dir}: #{error}" unless status.success?

    output
  end

  def launched(task = "Move me")
    run = queue_and_launch(task)
    git(run.target_root, "config", "user.email", "agent@example.test")
    git(run.target_root, "config", "user.name", "Agent")
    run
  end

  def refusal(run, to: "mac", **options)
    described_class.call(run, to:, **options)
  rescue described_class::NotMovable => error
    error.message
  end

  describe "refusing" do
    it "an unknown runner, its own runner, and a runner with no checkout, listing where it could go", :fake_herdr do
      run = launched
      RegisteredRunner.create!(name: "spare", kind: "remote", url: "http://spare.tailnet.test:3100")

      expect(refusal(run, to: "nope")).to include("no runner named \"nope\"", "local, mac")
      expect(refusal(run, to: "local")).to include("already on local")
      expect(refusal(run, to: "spare")).to include("spare has no checkout", "local, mac")
    end

    it "a run with no branch yet, or one queued to start", :fake_herdr do
      queued = create_run(workspace:, status: "queued")
      expect(refusal(queued)).to include("no branch yet")
      queued.update!(branch_name: "paneyard/queued")
      expect(refusal(queued)).to include("is queued")
    end

    it "a session still working unless forced, and then closes it mid-turn", :fake_herdr do
      run = launched
      session = run.live_session

      expect(refusal(run)).to include("still working", "force")
      expect(session.reload).to be_live
      expect(run.reload.runner.name).to eq("local")

      moved = described_class.call(run, to: "mac", force: true)

      expect(moved[:closed]).to include(worktree: "removed")
      expect(session.reload).not_to be_live
      expect(run.reload).to have_attributes(status: "queued")
      expect(run.runner.name).to eq("mac")
    end

    it "before closing anything when the destination cannot be reached", :fake_herdr do
      run = launched
      report(run, "done", "## Ready")
      allow(other).to receive(:known_commits).and_raise(Orchestrator::Runner::Unreachable, "runner \"mac\" did not answer")

      expect(refusal(run)).to include("did not answer")
      expect(run.reload.live_session).to be_present
      expect(run.runner.name).to eq("local")
    end
  end

  it "leaves the run where it was, with its worktree, when the import is refused after the session closed", :fake_herdr do
    run = launched
    File.write(File.join(run.target_root, "wip.txt"), "wip\n")
    report(run, "done", "## Ready")
    # A diverging branch of the same name on the other machine.
    git(there, "config", "user.email", "x@example.test")
    git(there, "config", "user.name", "X")
    git(there, "switch", "-q", "-c", run.branch_name)
    File.write(File.join(there, "theirs.txt"), "theirs\n")
    git(there, "add", "theirs.txt")
    git(there, "commit", "-q", "-m", "theirs")
    git(there, "switch", "-q", "main")
    here = run.target_root

    expect { described_class.call(run, to: "mac") }.to raise_error(described_class::Failed, /diverged.*still on local.*reopen it/m)

    run.reload
    expect(run.runner.name).to eq("local")
    expect(run.target_root).to eq(here)
    expect(File.read(File.join(here, "wip.txt"))).to eq("wip\n")
    expect(run.moves).to be_empty
    expect(Orchestrator::SessionReopen.problem(run)).to be_nil
  end

  it "records what crossed, and the janitor removes the worktree left behind once its work is saved", :fake_herdr do
    run = launched
    File.write(File.join(run.target_root, "feature.rb"), "feature\n")
    git(run.target_root, "add", "feature.rb")
    git(run.target_root, "commit", "-q", "-m", "Add feature")
    File.write(File.join(run.target_root, "wip.txt"), "wip\n")
    report(run, "done", "## Ready")
    here = run.target_root

    moved = described_class.call(run, to: "mac")

    move = run.moves.sole
    expect(moved).to include(from: "local", to: "mac", source_worktree: "kept", reopen_error: nil)
    expect(move).to have_attributes(from_runner: RegisteredRunner.local, to_runner: mac, source_target_root: here,
      source_worktree: "kept", target_root: run.reload.target_root)
    expect(move.transferred).to include("untracked_files" => [ "wip.txt" ], "branch_created" => true, "bundle_bytes" => be_positive)
    expect(Orchestrator::WorktreeJanitor.sweep(workspace)).to eq(0)

    # The operator deals with what was left: the untracked file goes, the
    # commit is merged into main.
    File.delete(File.join(here, "wip.txt"))
    git(workspace.repository_path, "merge", "-q", "--ff-only", run.branch_name)

    expect(Orchestrator::WorktreeJanitor.sweep(workspace)).to eq(1)
    expect(move.reload.source_worktree).to eq("removed")
    expect(File.exist?(here)).to be(false)
    # The run's own worktree, over there, is not the janitor's to touch: its session is queued again.
    expect(File.directory?(run.target_root)).to be(true)
  end

  it "moves a run to a runner with no checkout of the workspace, cloning one there first", :fake_herdr do
    nas_root = File.join(there_root, "nas")
    nas = RegisteredRunner.create!(name: "nas", kind: "remote", url: "http://nas.tailnet.test:3100", projects_dir: File.join(nas_root, "Source"))
    on_nas = Orchestrator::Runner::Local.new(runtime_root: File.join(nas_root, "run_sessions"))
    allow(Orchestrator::Runner).to receive(:resolve).and_wrap_original do |original, record|
      case record&.name
      when "mac" then other
      when "nas" then on_nas
      else original.call(record)
      end
    end
    # Where the other machine clones it from.
    workspace.update!(origin_url: workspace.repository_path)
    run = launched
    File.write(File.join(run.target_root, "wip.txt"), "wip\n")
    report(run, "done", "## Ready")
    expect(Orchestrator::RunMove.destinations(run)).to eq(%w[mac nas])

    moved = described_class.call(run, to: "nas")

    clone = File.join(nas_root, "Source", workspace.name)
    expect(moved).to include(from: "local", to: "nas", reopen_error: nil)
    expect(workspace.reload.repository_path_for(nas)).to eq(clone)
    expect(run.reload).to have_attributes(runner: nas, source_root: clone)
    expect(File.read(File.join(run.target_root, "wip.txt"))).to eq("wip\n")
  end

  it "refuses before closing anything when the destination cannot clone the workspace", :fake_herdr do
    nas = RegisteredRunner.create!(name: "nas", kind: "remote", url: "http://nas.tailnet.test:3100", projects_dir: File.join(there_root, "nas"))
    on_nas = Orchestrator::Runner::Local.new(runtime_root: File.join(there_root, "nas-rt"))
    allow(Orchestrator::Runner).to receive(:resolve).and_wrap_original do |original, record|
      record&.name == "nas" ? on_nas : original.call(record)
    end
    workspace.update!(origin_url: File.join(there_root, "no-such-origin.git"))
    run = launched
    report(run, "done", "## Ready")

    expect(refusal(run, to: "nas")).to include("Could not check workspace", "git clone")
    expect(run.reload.live_session).to be_present
    expect(run.runner.name).to eq("local")
    expect(workspace.checkouts.reload.map { |checkout| checkout.runner.name }).to contain_exactly("local", "mac")
  end

  it "is admin-only" do
    expect(Orchestrator::AdminMcpServer::TOOLS).to include(McpTools::MoveRunTool)
    expect(Orchestrator::RunMcpServer::TOOLS).not_to include(McpTools::MoveRunTool)
  end
end

require "rails_helper"
require "open3"

RSpec.describe Run, type: :model do
  # Real git, because #kept_worktree? now asks git whether target_root is an
  # actual worktree rather than trusting File.directory? -- see
  # the runner's #worktree_registered? (Orchestrator::Runner::Worktrees).
  describe "#kept_worktree?" do
    let(:root) { Dir.mktmpdir("run-kept-worktree") }
    let(:source_root) { File.join(root, "main") }
    let(:workspace) { Workspace.create!(name: "kept-worktree-#{SecureRandom.hex(4)}", root_path: root) }

    before do
      FileUtils.mkdir_p(source_root)
      git(source_root, "init", "--initial-branch=main")
      git(source_root, "config", "user.email", "run-spec@example.com")
      git(source_root, "config", "user.name", "Run Spec")
      File.write(File.join(source_root, "README.md"), "hello\n")
      git(source_root, "add", ".")
      git(source_root, "commit", "-m", "initial")
    end

    after { FileUtils.remove_entry(root) if File.exist?(root) }

    def git(dir, *args)
      _output, error, status = Open3.capture3("git", "-C", dir.to_s, *args)
      raise "git #{args.join(' ')} failed: #{error}" unless status.success?
    end

    def terminal_run(name, path, status: "failed")
      workspace.runs.create!(
        run_id: name, task: "Exercise #{name}", target_root: path, source_root: source_root,
        worktree_name: name, branch_name: "paneyard/#{name}", launcher_variant: "claude",
        status:, stopped_at: 1.day.ago
      )
    end

    it "is true for a real worktree left behind with unpushed work" do
      path = File.join(root, "real-worktree")
      git(source_root, "worktree", "add", "-b", "paneyard/real-worktree", path, "HEAD")
      File.write(File.join(path, "scratch.rb"), "unpushed\n")
      git(path, "add", "scratch.rb")
      git(path, "commit", "-m", "unpushed work")
      run = terminal_run("real-worktree", path)

      expect(run.kept_worktree?).to be(true)
    end

    # RunsController#create seeds target_root to the source checkout before
    # GitWorktree.provision! ever runs, so a run that dies before provisioning
    # leaves target_root pointing at `main` itself -- a real, existing
    # directory that is not a worktree of anything.
    it "is false for a run whose target_root was never provisioned past the source checkout" do
      run = terminal_run("never-provisioned", source_root)

      expect(run.kept_worktree?).to be(false)
    end

    # A directory `git worktree remove` already reclaimed, or one left behind
    # by an older version of the tool, still exists on disk but is unknown to
    # `git worktree list`.
    it "is false for a husk directory git no longer knows about" do
      path = File.join(root, "husk")
      FileUtils.mkdir_p(File.join(path, ".paneyard"))
      run = terminal_run("husk", path)

      expect(run.kept_worktree?).to be(false)
    end

    it "is false while the run's session is still live, even in a real worktree" do
      path = File.join(root, "still-live")
      git(source_root, "worktree", "add", "-b", "paneyard/still-live", path, "HEAD")
      run = terminal_run("still-live", path, status: "running")
      create_run_and_session(run:, prefix: "still-live")

      expect(run.kept_worktree?).to be(false)
    end
  end

  describe "sessions" do
    it "exposes only the live session as #live_session, and the newest as #latest_session" do
      run, first = create_run_and_session(prefix: "run-sessions")
      first.update!(status: "done", outcome: "done", ended_at: Time.current)
      _run, second = create_run_and_session(run:, prefix: "run-sessions")

      expect(run.live_session).to eq(second)
      expect(run.latest_session).to eq(second)

      second.update!(status: "closed", ended_at: Time.current)
      expect(run.reload.live_session).to be_nil
      expect(run.latest_session).to eq(second)
    end

    it "refuses a second live session for the same run, so one run can never hold two slots" do
      run, _session = create_run_and_session(prefix: "run-sessions")

      expect do
        create_run_and_session(run:, prefix: "run-sessions")
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end

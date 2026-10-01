require "rails_helper"
require "open3"

RSpec.describe Orchestrator::WorktreeJanitor, :fake_herdr do
  # A real git repo, because every safety rule here is expressed in terms of
  # what git actually reports: which worktrees exist, whether one is dirty,
  # whether its HEAD is in its run's base branch. Removal goes through herdr
  # (the fake one, which runs the real `git worktree remove`).
  let(:root) { Dir.mktmpdir("janitor") }
  let(:repository) { File.join(root, "my-app") }
  let(:workspace) { Workspace.create!(name: "janitor-#{SecureRandom.hex(4)}", repository_path: repository) }

  before do
    FileUtils.mkdir_p(repository)
    git(repository, "init", "--initial-branch=main")
    git(repository, "config", "user.email", "janitor@example.com")
    git(repository, "config", "user.name", "Janitor")
    File.write(File.join(repository, "README.md"), "hello\n")
    git(repository, "add", ".")
    git(repository, "commit", "-m", "initial")
    git(repository, "branch", "feature/payments")
  end

  after { FileUtils.remove_entry(root) if File.exist?(root) }

  def git(dir, *args)
    _output, error, status = Open3.capture3("git", "-C", dir.to_s, *args)
    raise "git #{args.join(' ')} failed: #{error}" unless status.success?
  end

  # Where herdr would put it is herdr's business; anywhere outside the
  # repository will do here.
  def add_worktree(name, base: "main")
    path = File.join(root, "worktrees", name)
    git(repository, "worktree", "add", "-b", "paneyard/#{name}", path, base)
    path
  end

  # A bare origin the repository pushes to, so "pushed" means what it means in
  # real use: HEAD is on a remote-tracking branch.
  def add_origin
    origin = File.join(root, "origin.git")
    git(root, "init", "--bare", origin)
    git(repository, "remote", "add", "origin", origin)
    origin
  end

  def commit_in(path, file)
    File.write(File.join(path, file), "#{file}\n")
    git(path, "add", file)
    git(path, "commit", "-m", "Add #{file}")
  end

  def terminal_run(name, path, stopped_at: 2.days.ago, status: "failed", base_branch: "main")
    workspace.runs.create!(
      run_id: name, task: "Exercise #{name}", target_root: path, source_root: repository,
      worktree_name: name, branch_name: "paneyard/#{name}", base_branch:, launcher_variant: "claude",
      status:, stopped_at:
    )
  end

  describe ".sweep" do
    it "reclaims a clean finished worktree whose HEAD is already in its base branch, through herdr" do
      path = add_worktree("old-failed")
      terminal_run("old-failed", path)

      expect(described_class.sweep(workspace)).to eq(1)
      expect(File.exist?(path)).to be(false)
      expect(fake_herdr.requests_for("worktree.remove").size).to eq(1)
    end

    # There is no age-based retention: commits that exist nowhere but this
    # branch keep their worktree however long ago the run ended.
    it "keeps a finished run with unpushed commits indefinitely, flagged as a kept worktree" do
      path = add_worktree("long-unpushed")
      commit_in(path, "unpushed.rb")
      run = terminal_run("long-unpushed", path, stopped_at: 1.year.ago)

      expect(described_class.sweep(workspace)).to eq(0)
      expect(File.exist?(path)).to be(true)
      expect(run.kept_worktree?).to be(true)
    end

    it "judges a run against its own base branch, not main" do
      from_payments = add_worktree("from-payments", base: "feature/payments")
      commit_in(from_payments, "fix.rb")
      git(repository, "merge", "--ff-only", "paneyard/from-payments")
      in_main_only = terminal_run("from-payments", from_payments, base_branch: "feature/payments")

      merged = add_worktree("merged-into-payments", base: "feature/payments")
      commit_in(merged, "other.rb")
      git(repository, "fetch", "-q", ".", "paneyard/merged-into-payments:feature/payments")
      terminal_run("merged-into-payments", merged, base_branch: "feature/payments")

      expect(described_class.sweep(workspace)).to eq(1)
      expect(File.exist?(merged)).to be(false)
      expect(File.exist?(from_payments)).to be(true)
      expect(in_main_only.kept_worktree?).to be(true)
    end

    # Only a run's own worktree is Paneyard's to reclaim. Anything else the
    # repository has -- the operator's own worktrees, leftovers no run owns --
    # is never looked at, however clean and merged.
    it "never reclaims a worktree no run owns" do
      path = add_worktree("not-a-run")

      expect(described_class.sweep(workspace)).to eq(0)
      expect(File.exist?(path)).to be(true)
      expect(fake_herdr.requests).to be_empty
    end

    it "reclaims a just-closed run straight away when its branch is already pushed" do
      add_origin
      path = add_worktree("just-pushed")
      commit_in(path, "pushed.rb")
      git(path, "push", "origin", "paneyard/just-pushed")
      terminal_run("just-pushed", path, stopped_at: 1.minute.ago, status: "awaiting_review")

      expect(described_class.sweep(workspace)).to eq(1)
      expect(File.exist?(path)).to be(false)
    end

    it "leaves a pushed run alone while its session is still live" do
      add_origin
      path = add_worktree("live-idle")
      git(path, "push", "origin", "paneyard/live-idle")
      run = terminal_run("live-idle", path, stopped_at: nil, status: "awaiting_review")
      create_run_and_session(run:, prefix: "live-idle")

      expect(described_class.sweep(workspace)).to eq(0)
      expect(File.exist?(path)).to be(true)
      expect(run.kept_worktree?).to be(false)
    end

    it "leaves an active run's worktree alone no matter how old the row is" do
      path = add_worktree("still-running")
      terminal_run("still-running", path, stopped_at: nil, status: "running")

      expect(described_class.sweep(workspace)).to eq(0)
      expect(File.exist?(path)).to be(true)
    end

    # git resolves symlinks in the paths it reports; a Run's target_root keeps
    # whatever string provisioned it. The tmpdirs here already differ that way
    # on macOS (/var vs /private/var); this spells it out where /tmp is not a
    # symlink.
    it "still finds the run's worktree when its target_root reaches it through a symlink" do
      path = add_worktree("symlinked")
      link_root = File.join(root, "link-to-root")
      File.symlink(root, link_root)
      terminal_run("symlinked", File.join(link_root, "worktrees", "symlinked"))

      expect(described_class.sweep(workspace)).to eq(1)
      expect(File.exist?(path)).to be(false)
    end

    # Uncommitted work in a failed run is exactly what an operator is most
    # likely to want back. Reclaiming it unattended would destroy it.
    it "refuses to reclaim a dirty worktree however long ago its run ended" do
      path = add_worktree("dirty")
      terminal_run("dirty", path)
      File.write(File.join(path, "scratch.rb"), "half-finished\n")

      expect(described_class.sweep(workspace)).to eq(0)
      expect(File.exist?(path)).to be(true)
    end

    it "never touches the repository's own checkout, even when a finished run points at it" do
      terminal_run("pointing-at-the-checkout", repository)

      expect(described_class.sweep(workspace)).to eq(0)
      expect(File.exist?(File.join(repository, "README.md"))).to be(true)
      expect(fake_herdr.requests).to be_empty
    end

    it "skips a run whose worktree is already gone" do
      path = add_worktree("hand-deleted")
      terminal_run("hand-deleted", path)
      FileUtils.remove_entry(path)

      expect(described_class.sweep(workspace)).to eq(0)
    end

    it "is a no-op for a workspace whose repository does not exist" do
      missing = Workspace.create!(name: "janitor-missing-#{SecureRandom.hex(4)}", repository_path: "/tmp/nope-#{SecureRandom.hex(4)}")
      missing.runs.create!(run_id: "gone", task: "x", target_root: "/tmp/nope-wt", worktree_name: "gone", launcher_variant: "claude", status: "failed")

      expect(described_class.sweep(missing)).to eq(0)
    end
  end

  describe ".release!" do
    it "removes a clean worktree whose branch is already merged into its base branch, keeping the branch" do
      path = add_worktree("merged")
      commit_in(path, "merged.rb")
      git(repository, "merge", "--ff-only", "paneyard/merged")
      run = terminal_run("merged", path, stopped_at: 1.minute.ago)

      expect(described_class.release!(run)).to be(true)
      expect(File.exist?(path)).to be(false)
      output, _error, _status = Open3.capture3("git", "-C", repository, "branch", "--list", "paneyard/merged")
      expect(output).to include("paneyard/merged")
    end

    it "removes a clean worktree whose branch is pushed" do
      add_origin
      path = add_worktree("pushed")
      commit_in(path, "pushed.rb")
      git(path, "push", "origin", "paneyard/pushed")
      run = terminal_run("pushed", path, stopped_at: 1.minute.ago)

      expect(described_class.release!(run)).to be(true)
      expect(File.exist?(path)).to be(false)
    end

    it "keeps a worktree with commits that are neither pushed nor merged" do
      path = add_worktree("unpushed")
      commit_in(path, "unpushed.rb")
      run = terminal_run("unpushed", path, stopped_at: 1.minute.ago)

      expect(described_class.release!(run)).to be(false)
      expect(File.exist?(path)).to be(true)
    end

    it "keeps a pushed worktree that has uncommitted changes" do
      add_origin
      path = add_worktree("pushed-dirty")
      git(path, "push", "origin", "paneyard/pushed-dirty")
      File.write(File.join(path, "scratch.rb"), "unsaved\n")
      run = terminal_run("pushed-dirty", path, stopped_at: 1.minute.ago)

      expect(described_class.release!(run)).to be(false)
      expect(File.exist?(path)).to be(true)
    end

    it "keeps a worktree whose base branch no longer exists, unless it is pushed" do
      path = add_worktree("orphaned-base", base: "feature/payments")
      run = terminal_run("orphaned-base", path, base_branch: "feature/payments")
      git(repository, "branch", "-D", "feature/payments")

      expect(described_class.release!(run)).to be(false)
      expect(File.exist?(path)).to be(true)
    end
  end

  describe ".remove_for_run!" do
    it "removes a clean worktree on the operator's explicit request" do
      path = add_worktree("explicit")
      run = terminal_run("explicit", path, stopped_at: 1.minute.ago)

      described_class.remove_for_run!(run)

      expect(File.exist?(path)).to be(false)
    end

    it "refuses a dirty worktree unless the operator forces it, and says why" do
      path = add_worktree("explicit-dirty")
      run = terminal_run("explicit-dirty", path, stopped_at: 1.minute.ago)
      File.write(File.join(path, "scratch.rb"), "unsaved\n")

      expect { described_class.remove_for_run!(run) }
        .to raise_error(Orchestrator::Runner::Error, /uncommitted changes/)
      expect(File.exist?(path)).to be(true)

      described_class.remove_for_run!(run, force: true)
      expect(File.exist?(path)).to be(false)
    end

    it "refuses to remove the repository's own checkout even when a run points at it" do
      run = terminal_run("source-pointing", repository, stopped_at: 1.minute.ago)

      expect { described_class.remove_for_run!(run) }
        .to raise_error(Orchestrator::Runner::Error, /Refusing to remove the repository's own checkout/)
      expect(File.exist?(File.join(repository, "README.md"))).to be(true)
    end
  end
end

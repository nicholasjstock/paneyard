require "rails_helper"
require "open3"

RSpec.describe Orchestrator::WorktreeJanitor do
  # A real git repo, because every safety rule here is expressed in terms of
  # what git actually reports: which worktrees exist, and whether one is dirty.
  let(:root) { Dir.mktmpdir("janitor") }
  let(:source_root) { File.join(root, "main") }
  let(:workspace) { Workspace.create!(name: "janitor-#{SecureRandom.hex(4)}", root_path: root) }

  before do
    FileUtils.mkdir_p(source_root)
    git(source_root, "init", "--initial-branch=main")
    git(source_root, "config", "user.email", "janitor@example.com")
    git(source_root, "config", "user.name", "Janitor")
    File.write(File.join(source_root, "README.md"), "hello\n")
    git(source_root, "add", ".")
    git(source_root, "commit", "-m", "initial")
  end

  after { FileUtils.remove_entry(root) if File.exist?(root) }

  def git(dir, *args)
    _output, error, status = Open3.capture3("git", "-C", dir.to_s, *args)
    raise "git #{args.join(' ')} failed: #{error}" unless status.success?
  end

  def add_worktree(name)
    path = File.join(root, name)
    git(source_root, "worktree", "add", "-b", "workflow/#{name}", path, "HEAD")
    path
  end

  # A bare origin the source checkout pushes to, so "pushed" means what it
  # means in real use: HEAD is on a remote-tracking branch.
  def add_origin
    origin = File.join(root, "origin.git")
    git(root, "init", "--bare", origin)
    git(source_root, "remote", "add", "origin", origin)
    origin
  end

  def commit_in(path, file)
    File.write(File.join(path, file), "#{file}\n")
    git(path, "add", file)
    git(path, "commit", "-m", "Add #{file}")
  end

  def terminal_run(name, path, stopped_at: 2.days.ago, status: "failed")
    workspace.runs.create!(
      run_id: name, task: "Exercise #{name}", target_root: path, source_root: source_root,
      worktree_name: name, branch_name: "workflow/#{name}", launcher_variant: "claude",
      status:, stopped_at:
    )
  end

  describe ".sweep" do
    it "reclaims a clean finished worktree whose HEAD is already on main" do
      path = add_worktree("old-failed")
      terminal_run("old-failed", path)

      expect(described_class.sweep(workspace)).to eq(1)
      expect(File.exist?(path)).to be(false)
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

    it "keeps an orphan worktree whose commits are not pushed or merged" do
      path = add_worktree("orphan-unpushed")
      commit_in(path, "unpushed.rb")

      expect(described_class.sweep(workspace)).to eq(0)
      expect(File.exist?(path)).to be(true)
    end

    it "reclaims a just-closed run straight away when its branch is already pushed" do
      add_origin
      path = add_worktree("just-pushed")
      commit_in(path, "pushed.rb")
      git(path, "push", "origin", "workflow/just-pushed")
      terminal_run("just-pushed", path, stopped_at: 1.minute.ago, status: "awaiting_review")

      expect(described_class.sweep(workspace)).to eq(1)
      expect(File.exist?(path)).to be(false)
    end

    it "leaves a pushed run alone while its session is still live" do
      add_origin
      path = add_worktree("live-idle")
      git(path, "push", "origin", "workflow/live-idle")
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
    # whatever string provisioned it. When those differ, an exact-string lookup
    # finds no owning run and the worktree of a live run looks like a
    # reclaimable orphan. The tmpdirs above already differ that way on macOS
    # (/var vs /private/var), so this spells the case out explicitly to keep it
    # covered where /tmp is not a symlink.
    it "still finds the owning run when its target_root reaches the worktree through a symlink" do
      path = add_worktree("symlinked")
      link_root = File.join(root, "link-to-root")
      File.symlink(root, link_root)
      terminal_run("symlinked", File.join(link_root, "symlinked"), stopped_at: nil, status: "running")

      expect(described_class.sweep(workspace)).to eq(0)
      expect(File.exist?(path)).to be(true)
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

    # Removing `main` would take the shared .git every worktree depends on.
    it "never touches the source checkout" do
      expect(described_class.sweep(workspace)).to eq(0)
      expect(File.exist?(source_root)).to be(true)
      expect(File.exist?(File.join(source_root, "README.md"))).to be(true)
    end

    it "reclaims an orphan worktree no run owns at all" do
      path = add_worktree("orphan")

      expect(described_class.sweep(workspace)).to eq(1)
      expect(File.exist?(path)).to be(false)
    end

    # git otherwise keeps listing a hand-deleted worktree as prunable forever.
    it "prunes entries whose directory was deleted by hand" do
      path = add_worktree("hand-deleted")
      FileUtils.remove_entry(path)

      described_class.sweep(workspace)

      output, _error, _status = Open3.capture3("git", "-C", source_root, "worktree", "list", "--porcelain")
      expect(output).not_to include("hand-deleted")
    end

    it "is a no-op for a workspace whose source checkout does not exist" do
      missing = Workspace.create!(name: "janitor-missing-#{SecureRandom.hex(4)}", root_path: "/tmp/nope-#{SecureRandom.hex(4)}")

      expect(described_class.sweep(missing)).to eq(0)
    end
  end

  describe ".release!" do
    it "removes a clean worktree whose branch is already merged into main, keeping the branch" do
      path = add_worktree("merged")
      commit_in(path, "merged.rb")
      git(source_root, "merge", "--ff-only", "workflow/merged")
      run = terminal_run("merged", path, stopped_at: 1.minute.ago)

      expect(described_class.release!(run)).to be(true)
      expect(File.exist?(path)).to be(false)
      output, _error, _status = Open3.capture3("git", "-C", source_root, "branch", "--list", "workflow/merged")
      expect(output).to include("workflow/merged")
    end

    it "removes a clean worktree whose branch is pushed" do
      add_origin
      path = add_worktree("pushed")
      commit_in(path, "pushed.rb")
      git(path, "push", "origin", "workflow/pushed")
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
      git(path, "push", "origin", "workflow/pushed-dirty")
      File.write(File.join(path, "scratch.rb"), "unsaved\n")
      run = terminal_run("pushed-dirty", path, stopped_at: 1.minute.ago)

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
        .to raise_error(described_class::Error, /uncommitted changes/)
      expect(File.exist?(path)).to be(true)

      described_class.remove_for_run!(run, force: true)
      expect(File.exist?(path)).to be(false)
    end

    it "refuses to remove the source checkout even when a run points at it" do
      run = terminal_run("source-pointing", source_root, stopped_at: 1.minute.ago)

      expect { described_class.remove_for_run!(run) }
        .to raise_error(described_class::Error, /Refusing to remove the source checkout/)
      expect(File.exist?(source_root)).to be(true)
    end
  end
end

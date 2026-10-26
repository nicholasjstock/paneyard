require "rails_helper"
require "open3"

# Real git: whether a switch could lose anything is only meaningful against it.
RSpec.describe Orchestrator::Runner::Repositories do
  let(:tmp) { Dir.mktmpdir("repositories") }

  after { FileUtils.remove_entry(tmp) if File.exist?(tmp) }

  def git(dir, *args)
    output, error, status = Open3.capture3("git", "-C", dir.to_s, *args)
    raise "git #{args.join(' ')} failed: #{error}" unless status.success?

    output.strip
  end

  # A clone of a bare origin with main and feature, main checked out.
  def checkout
    origin = File.join(tmp, "origin.git")
    seed = File.join(tmp, "seed")
    git(tmp, "init", "--bare", "--initial-branch=main", origin)
    git(tmp, "clone", "--quiet", origin, seed)
    git(seed, "config", "user.email", "lobby@example.test")
    git(seed, "config", "user.name", "Lobby")
    File.write(File.join(seed, "README.md"), "hi\n")
    git(seed, "add", ".")
    git(seed, "commit", "-m", "initial")
    git(seed, "push", "--quiet", "origin", "main")
    git(seed, "switch", "--quiet", "-c", "feature")
    File.write(File.join(seed, "feature.txt"), "feature\n")
    git(seed, "add", ".")
    git(seed, "commit", "-m", "feature")
    git(seed, "push", "--quiet", "origin", "feature")

    path = File.join(tmp, "app")
    git(tmp, "clone", "--quiet", origin, path)
    git(path, "config", "user.email", "lobby@example.test")
    git(path, "config", "user.name", "Lobby")
    File.realpath(path)
  end

  def switch!(path, branch)
    described_class.switch_checkout!(repository_path: path, branch:)
  end

  describe ".current_branch" do
    it "is the branch the checkout has checked out, or nil on a detached HEAD" do
      path = checkout
      git(path, "switch", "--quiet", "feature")
      expect(described_class.current_branch(path)).to eq("feature")

      git(path, "switch", "--quiet", "--detach")
      expect(described_class.current_branch(path)).to be_nil
    end
  end

  describe ".switch_checkout!" do
    it "leaves a checkout already on the branch alone" do
      path = checkout

      expect(switch!(path, "main")).to eq("branch" => "main", "previous_branch" => "main", "switched" => false)
    end

    it "switches a clean checkout to a local branch" do
      path = checkout
      git(path, "branch", "local-work", "main")

      expect(switch!(path, "local-work")).to eq("branch" => "local-work", "previous_branch" => "main", "switched" => true)
      expect(git(path, "branch", "--show-current")).to eq("local-work")
    end

    # A pull request's branch, never checked out here.
    it "fetches a branch only origin has and checks it out tracking origin" do
      path = checkout
      git(path, "update-ref", "-d", "refs/remotes/origin/feature")

      switch!(path, "feature")

      expect(git(path, "branch", "--show-current")).to eq("feature")
      expect(git(path, "rev-parse", "--abbrev-ref", "feature@{upstream}")).to eq("origin/feature")
      expect(File.read(File.join(path, "feature.txt"))).to eq("feature\n")
    end

    it "refuses a checkout with uncommitted changes to tracked files, and changes nothing" do
      path = checkout
      File.write(File.join(path, "README.md"), "edited\n")

      expect { switch!(path, "feature") }.to raise_error(Orchestrator::Runner::Error, /uncommitted changes \(M README.md\) on main/)
      expect(git(path, "branch", "--show-current")).to eq("main")
      expect(File.read(File.join(path, "README.md"))).to eq("edited\n")
    end

    it "switches past untracked files git can carry over" do
      path = checkout
      File.write(File.join(path, "notes.txt"), "mine\n")

      switch!(path, "feature")

      expect(git(path, "branch", "--show-current")).to eq("feature")
      expect(File.read(File.join(path, "notes.txt"))).to eq("mine\n")
    end

    it "passes on git's refusal of a branch checked out in a worktree" do
      path = checkout
      git(path, "worktree", "add", "--quiet", File.join(tmp, "run-worktree"), "-b", "paneyard/run", "main")

      expect { switch!(path, "paneyard/run") }.to raise_error(Orchestrator::Runner::Error, /git switch paneyard\/run failed/)
      expect(git(path, "branch", "--show-current")).to eq("main")
    end

    it "says so when neither the repository nor origin has the branch" do
      path = checkout

      expect { switch!(path, "nowhere") }.to raise_error(Orchestrator::Runner::Error, /has no branch `nowhere`, and origin has none either/)
    end

    it "refuses a name that is not a branch" do
      expect { switch!(checkout, "-x") }.to raise_error(Orchestrator::Runner::Error, /not a valid branch name/)
    end
  end
end

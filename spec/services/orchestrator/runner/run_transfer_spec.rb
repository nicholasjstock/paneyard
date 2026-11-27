require "rails_helper"
require "open3"

# Moving a run's work between two machines' checkouts, with real git: a bare
# origin, the source machine's checkout with the run's worktree, and the
# destination machine's own clone. Everything crosses as export returns it,
# through Runner::Wire as it would between processes, and lands through
# herdr (the fake one, which runs the real `git worktree add`).
RSpec.describe Orchestrator::Runner::RunTransfer, :fake_herdr do
  let(:root) { Dir.mktmpdir("run-transfer") }
  let(:origin) { File.join(root, "origin.git") }
  let(:source) { File.join(root, "here", "app") }
  let(:destination) { File.join(root, "there", "app") }
  let(:worktree) { File.join(root, "here", "worktrees", "move-me") }
  let(:branch) { "paneyard/move-me" }
  let(:base_sha) { git(source, "rev-parse", "main").strip }

  before do
    git(root, "init", "--bare", "-b", "main", origin)
    FileUtils.mkdir_p(source)
    git(source, "init", "-b", "main")
    configure(source)
    File.write(File.join(source, "README.md"), "hello\n")
    File.write(File.join(source, ".gitignore"), "ignored/\n*.log\n")
    File.binwrite(File.join(source, "logo.bin"), "\x00\x01\x02binary\xff".b)
    git(source, "add", ".")
    git(source, "commit", "-m", "initial")
    git(source, "remote", "add", "origin", origin)
    git(source, "push", "-q", "origin", "main")
    git(root, "clone", "-q", origin, destination)
    configure(destination)
    git(source, "worktree", "add", "-q", "-b", branch, worktree, "main")
  end

  after { FileUtils.remove_entry(root) if File.exist?(root) }

  def git(dir, *args)
    output, error, status = Open3.capture3("git", "-C", dir.to_s, *args)
    raise "git #{args.join(' ')} failed in #{dir}: #{error}" unless status.success?

    output
  end

  def configure(repository)
    git(repository, "config", "user.email", "transfer@example.test")
    git(repository, "config", "user.name", "Transfer")
  end

  def commit_in(path, file, content = "#{file}\n")
    File.write(File.join(path, file), content)
    git(path, "add", file)
    git(path, "commit", "-q", "-m", "Add #{file}")
  end

  # What crosses the wire between two runner processes.
  def across(value)
    Orchestrator::Runner::Wire.decode(JSON.parse(JSON.generate(Orchestrator::Runner::Wire.encode(value))))
  end

  def move!(path: worktree)
    have = described_class.known_commits(repository_path: destination, commits: [ base_sha ]).fetch("have")
    exported = across(described_class.export(repository_path: source, branch:, path:, exclude: have))
    imported = described_class.import(
      repository_path: destination, branch:, base_branch: "main", label: "move-me",
      head: exported.fetch("head"), bundle: exported["bundle"], worktree: exported["worktree"]
    )
    [ exported, imported ]
  end

  def state(path)
    {
      head: git(path, "rev-parse", "HEAD"), staged: git(path, "diff", "--cached", "--binary"),
      unstaged: git(path, "diff", "--binary"), status: git(path, "status", "--porcelain").lines.sort
    }
  end

  it "moves committed work only: a bundle of the commits since the base, and a clean worktree on the branch" do
    commit_in(worktree, "one.rb")
    commit_in(worktree, "two.rb")

    exported, imported = move!

    expect(exported["prerequisites"]).to eq([ base_sha ])
    expect(exported["bundle"].encoding).to eq(Encoding::BINARY)
    target = imported.fetch("target_root")
    expect(target).not_to eq(worktree)
    expect(target).to start_with(File.join(root, "there"))
    expect(imported).to include("branch" => branch, "branch_created" => true, "reused" => false)
    expect(git(destination, "rev-parse", "refs/heads/#{branch}")).to eq(git(source, "rev-parse", "refs/heads/#{branch}"))
    expect(state(target)).to eq(state(worktree))
    expect(git(target, "status", "--porcelain")).to be_empty
    expect(imported.fetch("fingerprint")).to eq(exported.dig("worktree", "fingerprint"))
    # Nothing was committed on either side, and nothing went to origin.
    expect(git(source, "rev-list", "--count", "main..#{branch}").strip).to eq("2")
    expect(git(origin, "branch", "--list", branch)).to be_empty
    expect(git(destination, "for-each-ref", "refs/paneyard-move")).to be_empty
  end

  it "moves staged and unstaged tracked changes, deletions and binary edits, and keeps what was staged staged" do
    commit_in(worktree, "kept.rb")
    File.write(File.join(worktree, "README.md"), "hello, staged\n")
    git(worktree, "add", "README.md")
    File.write(File.join(worktree, "README.md"), "hello, staged\nand unstaged\n")
    File.binwrite(File.join(worktree, "logo.bin"), "\x00\x02changed\xfe\xff".b)
    git(worktree, "add", "logo.bin")
    File.delete(File.join(worktree, "kept.rb"))

    exported, imported = move!

    expect(exported.dig("worktree", "changed")).to contain_exactly("README.md", "logo.bin", "kept.rb")
    target = imported.fetch("target_root")
    expect(state(target)).to eq(state(worktree))
    expect(File.binread(File.join(target, "logo.bin"))).to eq("\x00\x02changed\xfe\xff".b)
    expect(git(target, "diff", "--cached", "--name-only").split).to contain_exactly("README.md", "logo.bin")
    expect(git(target, "diff", "--name-only").split).to contain_exactly("README.md", "kept.rb")
  end

  it "moves untracked files, binary ones and symlinks too, with their modes, but nothing ignored" do
    FileUtils.mkdir_p(File.join(worktree, "notes", "deep"))
    File.write(File.join(worktree, "notes", "deep", "plan.md"), "plan\n")
    File.binwrite(File.join(worktree, "blob.dat"), Random.new(1).bytes(4096))
    File.write(File.join(worktree, "run.sh"), "#!/bin/sh\necho hi\n")
    File.chmod(0o755, File.join(worktree, "run.sh"))
    File.symlink("notes/deep/plan.md", File.join(worktree, "plan-link"))
    FileUtils.mkdir_p(File.join(worktree, "ignored"))
    File.write(File.join(worktree, "ignored", "cache"), "ignored\n")
    File.write(File.join(worktree, "debug.log"), "ignored\n")

    exported, imported = move!

    expect(exported.dig("worktree", "files")).to contain_exactly("notes/deep/plan.md", "blob.dat", "run.sh", "plan-link")
    target = imported.fetch("target_root")
    expect(File.binread(File.join(target, "blob.dat"))).to eq(File.binread(File.join(worktree, "blob.dat")))
    expect(File.stat(File.join(target, "run.sh")).mode & 0o777).to eq(0o755)
    expect(File.readlink(File.join(target, "plan-link"))).to eq("notes/deep/plan.md")
    expect(File.exist?(File.join(target, "ignored"))).to be(false)
    expect(File.exist?(File.join(target, "debug.log"))).to be(false)
    expect(state(target)).to eq(state(worktree))
  end

  it "carries the whole branch when the destination does not have the base commit (it was never pushed)" do
    commit_in(source, "local-only.rb")
    git(source, "worktree", "remove", worktree)
    git(source, "branch", "-D", branch)
    git(source, "worktree", "add", "-q", "-b", branch, worktree, "main")
    commit_in(worktree, "feature.rb")

    known = described_class.known_commits(repository_path: destination, commits: [ base_sha ])
    expect(known).to include("have" => [], "fetched" => true)

    exported, imported = move!

    expect(exported["prerequisites"]).to eq([])
    expect(git(imported.fetch("target_root"), "log", "--format=%s").lines.map(&:strip)).to eq([ "Add feature.rb", "Add local-only.rb", "initial" ])
  end

  it "moves just the branch when the worktree is gone" do
    commit_in(worktree, "saved.rb")
    git(source, "worktree", "remove", worktree)

    exported, imported = move!

    expect(exported["worktree"]).to be_nil
    expect(git(imported.fetch("target_root"), "log", "-1", "--format=%s").strip).to eq("Add saved.rb")
  end

  it "refuses a destination branch that has diverged, and leaves it and everything else there as it was" do
    commit_in(worktree, "mine.rb")
    git(destination, "branch", branch, "origin/main")
    other = File.join(root, "there", "scratch")
    git(destination, "worktree", "add", "-q", other, branch)
    commit_in(other, "theirs.rb")
    git(destination, "worktree", "remove", other)
    tip = git(destination, "rev-parse", branch)

    expect { move! }.to raise_error(Orchestrator::Runner::Error, /diverged/)

    expect(git(destination, "rev-parse", branch)).to eq(tip)
    expect(git(destination, "worktree", "list", "--porcelain").scan(/^worktree /).size).to eq(1)
    expect(fake_herdr.requests_for("worktree.create")).to be_empty
  end

  it "fast-forwards a destination branch that is behind, and reuses a clean worktree the run left there" do
    commit_in(worktree, "first.rb")
    _exported, imported = move!
    left_there = imported.fetch("target_root")
    git(destination, "worktree", "list") # the run's worktree there stays, clean, as if it had moved away again
    commit_in(worktree, "second.rb")
    File.write(File.join(worktree, "wip.txt"), "wip\n")

    _exported, again = move!

    expect(again).to include("reused" => true, "branch_created" => false, "target_root" => left_there)
    expect(git(left_there, "log", "-1", "--format=%s").strip).to eq("Add second.rb")
    expect(File.read(File.join(left_there, "wip.txt"))).to eq("wip\n")
  end

  it "refuses to reuse a worktree there with uncommitted changes of its own" do
    _exported, imported = move!
    File.write(File.join(imported.fetch("target_root"), "local.txt"), "local\n")
    commit_in(worktree, "more.rb")

    expect { move! }.to raise_error(Orchestrator::Runner::Error, /uncommitted changes/)
    expect(File.read(File.join(imported.fetch("target_root"), "local.txt"))).to eq("local\n")
  end

  describe "moving back to the machine it left" do
    def move_back!(from_path, replaceable:)
      exported = across(described_class.export(repository_path: destination, branch:, path: from_path, exclude: [ base_sha ]))
      described_class.import(repository_path: source, branch:, base_branch: "main", label: "move-me",
        head: exported.fetch("head"), bundle: exported["bundle"], worktree: exported["worktree"], replaceable:)
    end

    before do
      commit_in(worktree, "first.rb")
      File.write(File.join(worktree, "wip.txt"), "wip\n")
      File.write(File.join(worktree, "README.md"), "edited\n")
    end

    it "resets and reuses the dirty worktree it left there while it is exactly as it was carried away" do
      exported, imported = move!
      there = imported.fetch("target_root")
      configure(there)
      commit_in(there, "second.rb")
      File.delete(File.join(there, "wip.txt"))
      File.write(File.join(there, "newer.txt"), "newer\n")

      back = move_back!(there, replaceable: [ { "path" => worktree, "fingerprint" => exported.dig("worktree", "fingerprint") } ])

      expect(back).to include("reused" => true, "target_root" => File.realpath(worktree))
      expect(state(worktree)).to eq(state(there))
      expect(File.exist?(File.join(worktree, "wip.txt"))).to be(false)
      expect(File.read(File.join(worktree, "newer.txt"))).to eq("newer\n")
    end

    it "refuses it once something there changed after the run left" do
      exported, imported = move!
      File.write(File.join(worktree, "after-it-left.txt"), "mine\n")

      expect do
        move_back!(imported.fetch("target_root"), replaceable: [ { "path" => worktree, "fingerprint" => exported.dig("worktree", "fingerprint") } ])
      end.to raise_error(Orchestrator::Runner::Error, /did not go with the run/)
      expect(File.read(File.join(worktree, "after-it-left.txt"))).to eq("mine\n")
      expect(File.read(File.join(worktree, "wip.txt"))).to eq("wip\n")
    end
  end

  it "undoes its own worktree and branch when the result does not match the source" do
    commit_in(worktree, "one.rb")
    File.write(File.join(worktree, "README.md"), "changed\n")
    have = described_class.known_commits(repository_path: destination, commits: [ base_sha ]).fetch("have")
    exported = across(described_class.export(repository_path: source, branch:, path: worktree, exclude: have))
    exported["worktree"]["fingerprint"]["worktree"] = "0" * 40

    expect do
      described_class.import(repository_path: destination, branch:, base_branch: "main", label: "move-me",
        head: exported.fetch("head"), bundle: exported["bundle"], worktree: exported["worktree"])
    end.to raise_error(Orchestrator::Runner::Error, /does not match/)

    expect(git(destination, "branch", "--list", branch)).to be_empty
    expect(git(destination, "worktree", "list", "--porcelain").scan(/^worktree /).size).to eq(1)
    # The source is untouched.
    expect(File.read(File.join(worktree, "README.md"))).to eq("changed\n")
  end

  it "deletes the branch it made when herdr cannot make the worktree" do
    commit_in(worktree, "one.rb")
    allow(Orchestrator::Runner::Herdr).to receive(:worktree_create).and_raise(Orchestrator::Runner::Herdr::Error, "no room")

    expect { move! }.to raise_error(Orchestrator::Runner::Error, /no room/)

    expect(git(destination, "branch", "--list", branch)).to be_empty
  end

  it "refuses a worktree that is not on the run's branch" do
    git(worktree, "checkout", "-q", "--detach")

    expect do
      described_class.export(repository_path: source, branch:, path: worktree)
    end.to raise_error(Orchestrator::Runner::Error, /not on branch/)
  end

  it "is refused outside a sandbox's root" do
    allow(Orchestrator::Sandbox).to receive(:enabled?).and_return(true)
    allow(PaneyardSandbox).to receive(:root).and_return(File.join(root, "elsewhere"))

    expect { described_class.export(repository_path: source, branch:, path: worktree) }
      .to raise_error(Orchestrator::Runner::Error, /sandbox refuses/)
    expect { described_class.known_commits(repository_path: destination, commits: [ base_sha ]) }
      .to raise_error(Orchestrator::Runner::Error, /sandbox refuses/)
  end

  it "does not fetch from an origin outside a sandbox's root" do
    allow(Orchestrator::Sandbox).to receive(:enabled?).and_return(true)
    allow(PaneyardSandbox).to receive(:root).and_return(File.join(root, "there"))

    known = described_class.known_commits(repository_path: destination, commits: [ "a" * 40 ])

    expect(known).to include("have" => [], "fetched" => false, "fetch_error" => /sandbox refuses/)
  end
end

require "rails_helper"
require "open3"

# Real git, because every rule here is a question about what git reports:
# whether a directory is a checkout, which branch it is on, what its remotes are.
RSpec.describe Orchestrator::Runner::WorkspaceRoots do
  let(:tmp) { Dir.mktmpdir("workspace-roots") }
  let(:runner) { Orchestrator::Runner::Local.new(runtime_root: tmp) }

  after { FileUtils.remove_entry(tmp) if File.exist?(tmp) }

  def git(dir, *args)
    output, error, status = Open3.capture3("git", "-C", dir.to_s, *args)
    raise "git #{args.join(' ')} failed: #{error}" unless status.success?

    output
  end

  def checkout(path, branch: "main", origin: "https://example.test/demo.git")
    FileUtils.mkdir_p(path)
    git(path, "init", "--initial-branch=#{branch}")
    git(path, "config", "user.email", "roots@example.test")
    git(path, "config", "user.name", "Roots")
    File.write(File.join(path, "README.md"), "hi\n")
    git(path, "add", ".")
    git(path, "commit", "-m", "initial")
    git(path, "remote", "add", "origin", origin) if origin
    path
  end

  def check(path)
    runner.check_workspace_root(root_path: path)
  end

  def codes(result)
    result.fetch("problems").map { |problem| problem.fetch("code") }
  end

  it "accepts a root holding a main checkout on main with an origin, and reports what it found" do
    root = File.join(tmp, "demo")
    checkout(File.join(root, "main"))

    result = check(root)

    expect(result).to eq(
      "root_path" => root, "source_root" => File.join(root, "main"),
      "origin_url" => "https://example.test/demo.git", "problems" => []
    )
  end

  it "expands ~ and tidies the path" do
    home = File.join(tmp, "home")
    checkout(File.join(home, "code", "demo", "main"))
    original = ENV["HOME"]
    ENV["HOME"] = home

    expect(check("~/code/demo/")).to include("root_path" => File.join(home, "code", "demo"), "problems" => [])
  ensure
    ENV["HOME"] = original
  end

  it "refuses a relative, missing, or non-directory root" do
    file = File.join(tmp, "file")
    File.write(file, "")

    expect(codes(check("code/demo"))).to eq(%w[root_path_not_absolute])
    expect(codes(check(""))).to eq(%w[root_path_blank])
    expect(codes(check(File.join(tmp, "nope")))).to eq(%w[root_path_missing])
    expect(check(File.join(tmp, "nope")).dig("problems", 0, "message")).to include("git clone <repository-url> #{tmp}/nope/main")
    expect(codes(check(file))).to eq(%w[root_path_not_directory])
  end

  # Where an agent is usually opened: the main checkout, somewhere inside it,
  # or a run's worktree beside it. All mean the same workspace.
  it "works out the workspace root from the main checkout, a directory in it, or a worktree beside it" do
    root = File.join(tmp, "demo")
    source = checkout(File.join(root, "main"))
    FileUtils.mkdir_p(File.join(source, "app", "models"))
    worktree = File.join(root, "fix-it-1a2b")
    git(source, "worktree", "add", "-b", "paneyard/fix-it-1a2b", worktree, "HEAD")

    [ source, "#{source}/", File.join(source, "app", "models"), worktree ].each do |path|
      expect(check(path)).to eq(
        "root_path" => root, "source_root" => File.join(root, "main"),
        "origin_url" => "https://example.test/demo.git", "problems" => []
      ), path
    end
  end

  it "still reports what is wrong with a main checkout it was pointed into" do
    root = File.join(tmp, "demo")
    source = checkout(File.join(root, "main"), branch: "master")

    result = check(source)

    expect(result["root_path"]).to eq(root)
    expect(codes(result)).to eq(%w[source_not_on_main])
  end

  it "explains the <root>/main layout for a plain clone, with the commands to set it up" do
    root = checkout(File.join(tmp, "demo"))
    FileUtils.mkdir_p(File.join(root, "lib"))

    message = check(root).dig("problems", 0, "message")

    expect(codes(check(root))).to eq(%w[root_path_is_repository])
    expect(check(File.join(root, "lib"))).to include("root_path" => root)
    expect(message).to include("mkdir -p #{tmp}/demo-workspace")
    expect(message).to include("git clone https://example.test/demo.git #{tmp}/demo-workspace/main")
    expect(Dir.children(tmp)).to eq([ "demo" ])
  end

  it "says how to clone into an empty root" do
    root = File.join(tmp, "demo")
    FileUtils.mkdir_p(root)

    expect(codes(check(root))).to eq(%w[source_missing])
    expect(check(root).dig("problems", 0, "message")).to include("git clone <repository-url> #{root}/main")
  end

  it "refuses a main directory that is not a checkout of its own" do
    root = checkout(File.join(tmp, "demo"))
    FileUtils.mkdir_p(File.join(root, "main"))
    File.write(File.join(root, "main", "x"), "")

    expect(codes(check(root))).to eq(%w[source_not_git])
  end

  it "says how to get a master checkout onto main, and reports a missing origin as well" do
    root = File.join(tmp, "demo")
    source = checkout(File.join(root, "main"), branch: "master", origin: nil)

    result = check(root)

    expect(codes(result)).to eq(%w[source_not_on_main no_origin])
    expect(result.dig("problems", 0, "message")).to include("`master` checked out", "git -C #{source} branch -m master main")
    expect(result.dig("problems", 1, "message")).to include("git -C #{source} remote add origin <repository-url>")
    expect(result["origin_url"]).to be_nil
  end

  it "says to switch when a local main exists but another branch is checked out" do
    root = File.join(tmp, "demo")
    source = checkout(File.join(root, "main"))
    git(source, "switch", "-c", "feature")

    expect(check(root).dig("problems", 0, "message")).to include("`feature` checked out", "git -C #{source} switch main")
  end

  it "shares its checkout rules with every launch" do
    root = File.join(tmp, "demo")
    checkout(File.join(root, "main"), branch: "master")

    expect { Orchestrator::Runner::Worktrees.validate_source!(Pathname(root).join("main")) }
      .to raise_error(Orchestrator::Runner::Error, /must be on main.*branch -m master main/)
  end

  it "never changes anything on disk" do
    root = checkout(File.join(tmp, "demo"), branch: "master", origin: nil)
    before = git(root, "status", "--porcelain", "--branch")

    check(root)
    check(File.join(tmp, "missing"))

    expect(git(root, "status", "--porcelain", "--branch")).to eq(before)
    expect(Dir.children(tmp)).to eq([ "demo" ])
  end
end

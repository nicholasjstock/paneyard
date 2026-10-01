require "rails_helper"
require "open3"

RSpec.describe McpTools::RegisterWorkspaceTool do
  let(:tmp) { Dir.mktmpdir("register-workspace") }

  after { FileUtils.remove_entry(tmp) if File.exist?(tmp) }

  def git(dir, *args)
    output, error, status = Open3.capture3("git", "-C", dir.to_s, *args)
    raise "git #{args.join(' ')} failed: #{error}" unless status.success?

    output.strip
  end

  # An ordinary checkout: any directory name, any branch checked out.
  def checkout(name, branch: "main", origin: true)
    path = File.join(tmp, name)
    FileUtils.mkdir_p(path)
    git(path, "init", "--initial-branch=#{branch}")
    git(path, "config", "user.email", "register@example.test")
    git(path, "config", "user.name", "Register")
    File.write(File.join(path, "README.md"), "hi\n")
    git(path, "add", ".")
    git(path, "commit", "-m", "initial")
    git(path, "remote", "add", "origin", "https://example.test/#{name}.git") if origin
    File.realpath(path)
  end

  def call(path, **arguments)
    described_class.call(path:, server_context: {}, **arguments)
  end

  def problem_codes(response)
    response.structured_content[:problems].map { |problem| problem[:code] }
  end

  it "registers an ordinary existing checkout directly, named after its directory" do
    repository = checkout("my-app")

    response = nil
    expect { response = call(repository) }.to change(Workspace, :count).by(1)

    expect(response.error?).to be(false)
    expect(response.structured_content).to include(
      name: "my-app", repositoryPath: repository, defaultBaseBranch: "main",
      originUrl: "https://example.test/my-app.git", activeRuns: 0
    )
    expect(Workspace.find_by!(name: "my-app")).to have_attributes(repository_path: repository, default_base_branch: "main")
  end

  it "uses the repository's own default branch, not whatever is checked out" do
    repository = checkout("busy")
    git(repository, "switch", "-q", "-c", "feature/half-done")

    response = call(repository)

    expect(response.structured_content).to include(defaultBaseBranch: "main")
    expect(git(repository, "branch", "--show-current")).to eq("feature/half-done")
  end

  it "prefers origin's HEAD when the repository knows it" do
    repository = checkout("trunk-based", branch: "trunk")
    git(repository, "update-ref", "refs/remotes/origin/trunk", "HEAD")
    git(repository, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk")
    git(repository, "branch", "main")

    expect(call(repository).structured_content).to include(defaultBaseBranch: "trunk")
  end

  it "takes an explicit default base branch, and the name it is given" do
    repository = checkout("explicit")
    git(repository, "branch", "develop")

    response = call(repository, name: "mine", defaultBaseBranch: "develop")

    expect(response.structured_content).to include(name: "mine", defaultBaseBranch: "develop")
  end

  it "refuses a default base branch the repository does not have locally, and says how to fix it" do
    repository = checkout("no-develop")
    git(repository, "update-ref", "refs/remotes/origin/develop", "HEAD")

    response = call(repository, defaultBaseBranch: "develop")

    expect(problem_codes(response)).to eq(%w[base_branch_missing])
    expect(response.structured_content[:message]).to include("git -C #{repository} branch develop origin/develop")
    expect(Workspace.count).to eq(0)
  end

  it "works out the repository from a directory inside it, or from a linked worktree of it" do
    repository = checkout("nested")
    FileUtils.mkdir_p(File.join(repository, "app", "models"))
    worktree = File.join(tmp, "elsewhere", "nested-wt")
    git(repository, "worktree", "add", "-q", "-b", "side", worktree)

    expect(call(File.join(repository, "app", "models")).structured_content).to include(repositoryPath: repository)
    Workspace.delete_all
    expect(call(worktree).structured_content).to include(repositoryPath: repository)
  end

  it "creates nothing for a directory that is not in a git checkout" do
    plain = File.join(tmp, "plain")
    FileUtils.mkdir_p(plain)

    expect(problem_codes(call(plain))).to eq(%w[not_git])
    expect(Workspace.count).to eq(0)
  end

  it "returns every problem at once: a taken name, no default branch to be found, and no origin" do
    create_workspace(prefix: "taken").update!(name: "taken")
    repository = checkout("odd", branch: "work", origin: false)

    response = call(repository, name: "taken")

    expect(response.error?).to be(true)
    expect(problem_codes(response)).to eq(%w[name_taken no_default_branch no_origin])
    expect(response.structured_content[:message]).to start_with("Nothing was registered.").and include("1. ", "2. ", "3. ")
    expect(Workspace.where(name: "taken").count).to eq(1)
  end

  it "refuses a repository another workspace already has, however it is reached" do
    repository = checkout("demo")
    Workspace.create!(name: "first", repository_path: repository)

    response = call("#{repository}/", name: "second")

    expect(problem_codes(response)).to eq(%w[repository_taken])
    expect(response.structured_content[:message]).to include('Workspace "first" is already registered')
    expect(Workspace.find_by(name: "second")).to be_nil
  end

  it "picks a free name when the directory's is taken" do
    create_workspace(prefix: "x").update!(name: "dup")
    repository = checkout("dup")

    expect(call(repository).structured_content).to include(name: "dup-2")
  end
end

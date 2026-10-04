require "rails_helper"
require "open3"

# The merge signal is git's, so these use a real repository: a dependency's
# branch is made the way herdr makes it (from main, base_sha recorded), and
# merged, or not, by hand.
RSpec.describe Orchestrator::RunDependencies do
  let(:repository) { create_source_checkout }
  let(:workspace) { create_workspace(prefix: "deps", repository_path: repository) }
  let(:dependency) { launched("deps-a") }
  let(:dependent) { create_run(workspace:, prefix: "deps-b", status: "queued", base_branch: "main", dependency_run_ids: [ dependency.run_id ]) }

  def git(*args)
    out, status = Open3.capture2e("git", "-C", repository, *args)
    raise out unless status.success?

    out.strip
  end

  # A run that launched: its branch, from main as it is now.
  def launched(prefix, status: "running")
    branch = "paneyard/#{prefix}"
    git("branch", branch, "main")
    create_run(workspace:, prefix:, status:, base_branch: "main", branch_name: branch, base_sha: git("rev-parse", "main"))
  end

  def commit_on(branch, file)
    git("switch", "-q", branch)
    File.write(File.join(repository, file), "#{file}\n")
    git("add", file)
    git("commit", "-qm", "Add #{file}")
    git("switch", "-q", "main")
  end

  it "waits while the dependency has no work of its own, though its branch is in main" do
    expect(described_class.status(dependent)).to include(state: "waiting", reason: include(dependency.run_id, "`main`"))
    expect(described_class.ready?(dependent)).to be(false)
  end

  it "waits while the dependency's commits are not in main" do
    commit_on(dependency.branch_name, "a.txt")

    expect(described_class.status(dependent)).to include(state: "waiting",
      runs: [ { run_id: dependency.run_id, status: "running", merged: false } ])
  end

  it "is met once the dependency's commits are merged into main, by fast-forward or merge commit" do
    commit_on(dependency.branch_name, "a.txt")
    git("merge", "-q", "--ff-only", dependency.branch_name)
    other = launched("deps-c")
    commit_on(other.branch_name, "c.txt")
    commit_on("main", "main.txt")
    git("merge", "-q", "--no-ff", "-m", "Merge c", other.branch_name)
    dependent.update!(dependency_run_ids: [ dependency.run_id, other.run_id ])

    expect(described_class.status(dependent)).to include(state: "met", reason: nil)
    expect(described_class.ready?(dependent)).to be(true)
  end

  it "does not see a squash merge" do
    commit_on(dependency.branch_name, "a.txt")
    git("merge", "-q", "--squash", dependency.branch_name)
    git("commit", "-qm", "Squashed")

    expect(described_class.status(dependent)[:state]).to eq("waiting")
  end

  it "is blocked when a dependency failed or stopped without its work merged, and says why" do
    dependency.update!(status: "failed")
    stopped = create_run(workspace:, prefix: "deps-stopped", status: "stopped", base_branch: "main")
    dependent.update!(dependency_run_ids: [ dependency.run_id, stopped.run_id ])

    status = described_class.status(dependent)

    expect(status).to include(state: "blocked")
    expect(status[:reason]).to include("#{dependency.run_id} failed and #{stopped.run_id} stopped", "update_run_dependencies")
    expect(described_class.ready?(dependent)).to be(false)
  end

  it "counts a failed dependency's work that was merged anyway" do
    commit_on(dependency.branch_name, "a.txt")
    git("merge", "-q", "--ff-only", dependency.branch_name)
    dependency.update!(status: "failed")

    expect(described_class.status(dependent)[:state]).to eq("met")
  end

  it "no longer gates a run that has launched before, e.g. one being reopened" do
    dependent.update!(branch_name: "paneyard/deps-b")

    expect(described_class.status(dependent)).to be_nil
    expect(described_class.ready?(dependent)).to be(true)
  end
end

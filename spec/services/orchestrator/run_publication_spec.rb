require "rails_helper"
require "open3"

RSpec.describe Orchestrator::RunPublication do
  # Real git throughout, against a real bare "origin" on disk: the push is the
  # step most likely to break in a way a stub would hide, and head_sha vs
  # base_sha is what decides whether there is anything to publish at all.
  # Only `gh` is stubbed.
  let(:root) { Dir.mktmpdir("publication") }
  let(:source_root) { File.join(root, "main") }
  let(:origin) { File.join(root, "origin.git") }
  let(:workspace) { Workspace.create!(name: "publication-#{SecureRandom.hex(4)}", root_path: root) }

  before do
    git(root, "init", "--bare", origin)
    FileUtils.mkdir_p(source_root)
    git(source_root, "init", "--initial-branch=main")
    git(source_root, "config", "user.email", "pub@example.com")
    git(source_root, "config", "user.name", "Publisher")
    git(source_root, "remote", "add", "origin", origin)
    File.write(File.join(source_root, "README.md"), "hello\n")
    git(source_root, "add", ".")
    git(source_root, "commit", "-m", "initial")
    git(source_root, "push", "-u", "origin", "main")

    allow(Orchestrator::SessionEnv).to receive(:git_env).and_return({})
  end

  after { FileUtils.remove_entry(root) if File.exist?(root) }

  def git(dir, *args)
    _output, error, status = Open3.capture3("git", "-C", dir.to_s, *args)
    raise "git #{args.join(' ')} failed: #{error}" unless status.success?
  end

  # Provisions a real worktree and returns the run pointing at it.
  def provisioned_run(name, commit: true)
    path = File.join(root, name)
    base_sha = `git -C #{source_root} rev-parse HEAD`.strip
    git(source_root, "worktree", "add", "-b", "workflow/#{name}", path, base_sha)
    if commit
      File.write(File.join(path, "change.rb"), "puts :hello\n")
      git(path, "add", ".")
      git(path, "-c", "user.email=pub@example.com", "-c", "user.name=Publisher", "commit", "-m", "do the work")
    end
    workspace.runs.create!(
      run_id: name, task: "Publish #{name}", target_root: path, source_root: source_root,
      worktree_name: name, branch_name: "workflow/#{name}", base_sha: base_sha,
      launcher_variant: "claude", status: "running"
    )
  end

  def stub_gh(create_url: "https://github.com/example/repo/pull/7", view_success: false)
    allow(Open3).to receive(:capture3).and_call_original
    allow(Open3).to receive(:capture3)
      .with(anything, "gh", "pr", "view", anything, "--json", "url,isDraft", any_args)
      .and_return(view_success ? [ '{"url":"https://github.com/example/repo/pull/7","isDraft":false}', "", instance_double(Process::Status, success?: true) ]
                               : [ "", "no pull requests found", instance_double(Process::Status, success?: false) ])
    allow(Open3).to receive(:capture3)
      .with(anything, "gh", "pr", "create", any_args)
      .and_return([ "#{create_url}\n", "", instance_double(Process::Status, success?: true) ])
  end

  describe ".publish!" do
    it "pushes the branch and opens a pull request with run-summary.md as its body" do
      run = provisioned_run("publish-happy")
      Orchestrator::ArtifactStore.write(run.target_root, run.run_id, "run-summary.md", "## What changed\n\nAdded a thing.")
      stub_gh

      expect(described_class.publish!(run)).to eq(:published)

      expect(Open3).to have_received(:capture3).with(
        anything, "gh", "pr", "create", "--base", "main", "--head", "workflow/publish-happy",
        "--title", "Publish publish-happy", "--body", a_string_including("Added a thing."), any_args
      )
      expect(run.reload).to have_attributes(
        status: "awaiting_review", publication_status: "awaiting_approval",
        pull_request_url: "https://github.com/example/repo/pull/7"
      )
      # The push really happened, against a real remote.
      expect(`git -C #{origin} branch --list workflow/publish-happy`).to include("workflow/publish-happy")
    end

    # The session is told to write run-summary.md, but a missing file must not
    # cost the operator the whole pull request.
    it "still opens the PR with a fallback body when the session wrote no summary" do
      run = provisioned_run("publish-no-summary")
      stub_gh

      described_class.publish!(run)

      expect(Open3).to have_received(:capture3).with(
        anything, "gh", "pr", "create", "--base", "main", "--head", "workflow/publish-no-summary",
        "--title", anything, "--body", a_string_including(run.run_id), any_args
      )
    end

    it "completes a run that produced no commits instead of opening an empty PR" do
      run = provisioned_run("publish-nothing", commit: false)
      stub_gh

      expect(described_class.publish!(run)).to eq(:no_changes)

      expect(run.reload).to have_attributes(status: "completed", publication_status: "no_changes")
      expect(Open3).not_to have_received(:capture3).with(anything, "gh", "pr", "create", any_args)
    end

    it "refuses to publish directly from the source checkout" do
      run = workspace.runs.create!(
        run_id: "publish-source", task: "Publish from main", target_root: source_root, source_root: source_root,
        worktree_name: "publish-source", branch_name: "main", launcher_variant: "claude", status: "running"
      )

      expect { described_class.publish!(run) }
        .to raise_error(described_class::Error, /Refusing to publish directly from the source checkout/)
    end

    # A run whose branch never reached GitHub is not a completed run.
    it "fails the run when gh cannot open the pull request" do
      run = provisioned_run("publish-broken")
      allow(Open3).to receive(:capture3).and_call_original
      allow(Open3).to receive(:capture3).with(anything, "gh", "pr", "view", any_args)
        .and_return([ "", "not found", instance_double(Process::Status, success?: false) ])
      allow(Open3).to receive(:capture3).with(anything, "gh", "pr", "create", any_args)
        .and_return([ "", "gh: could not create pull request", instance_double(Process::Status, success?: false) ])

      expect { described_class.publish!(run) }.to raise_error(described_class::Error, /gh pr create failed/)

      expect(run.reload).to have_attributes(status: "failed", publication_status: "failed")
      expect(run.publication_error).to include("could not create pull request")
    end

    # A run can finish twice: a reviewer sends the session more work and it
    # pushes again to a branch whose PR is already open.
    it "comments on an already-open pull request rather than opening a second one" do
      run = provisioned_run("publish-again")
      Orchestrator::ArtifactStore.write(run.target_root, run.run_id, "run-summary.md", "Second pass.")
      stub_gh(view_success: true)
      allow(described_class).to receive(:post_comment!).and_return({ "id" => 12_345 })

      described_class.publish!(run)

      expect(described_class).to have_received(:post_comment!)
        .with(anything, "https://github.com/example/repo/pull/7", a_string_including("Second pass."), anything)
      expect(Open3).not_to have_received(:capture3).with(anything, "gh", "pr", "create", any_args)
      expect(RunOutboundComment.where(run_id: run.run_id, github_comment_id: "12345")).to exist
    end
  end

  describe ".cleanup_merged_run!" do
    it "removes the worktree and completes the run once GitHub reports the PR merged" do
      run = provisioned_run("cleanup-merged")
      run.update!(pull_request_url: "https://github.com/example/repo/pull/7", publication_status: "awaiting_approval")
      allow(described_class).to receive(:merged?).and_return(true)
      allow(Orchestrator::SourceCheckoutSync).to receive(:after_merge!)

      expect(described_class.cleanup_merged_run!(run)).to eq(:merged)

      expect(File.exist?(run.target_root)).to be(false)
      expect(run.reload).to have_attributes(status: "completed", publication_status: "merged")
      expect(Orchestrator::SourceCheckoutSync).to have_received(:after_merge!).with(run)
    end

    it "leaves an unmerged run entirely alone" do
      run = provisioned_run("cleanup-unmerged")
      run.update!(pull_request_url: "https://github.com/example/repo/pull/7", publication_status: "awaiting_approval")
      allow(described_class).to receive(:merged?).and_return(false)

      expect(described_class.cleanup_merged_run!(run)).to eq(:awaiting_confirmation)
      expect(File.exist?(run.target_root)).to be(true)
      expect(run.reload.status).to eq("running")
    end
  end
end

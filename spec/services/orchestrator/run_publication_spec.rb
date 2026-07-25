require "rails_helper"

RSpec.describe Orchestrator::RunPublication do
  it "commits source changes but keeps runtime artifacts and the PR summary out of Git" do
    root = Dir.mktmpdir
    git(root, "init")
    git(root, "config", "user.name", "Workflow Orchestrator")
    git(root, "config", "user.email", "workflow@example.test")
    File.write(File.join(root, "existing.txt"), "before\n")
    git(root, "add", "existing.txt")
    git(root, "commit", "-m", "Initial commit")
    workspace = Workspace.create!(name: "publication-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "publication-#{SecureRandom.hex(4)}", task: "Publish nothing", target_root: root,
      launcher_variant: "codex", status: "running", worktree_name: "publish-nothing-a1b2",
      branch_name: "workflow/publish-nothing-a1b2"
    )
    File.write(File.join(root, "existing.txt"), "after\n")
    Orchestrator::ArtifactStore.write(root, run.run_id, "run-summary.md", "## Result\n\nSource change verified.")
    Orchestrator::ArtifactStore.write(root, run.run_id, "worker.log", "sensitive runtime output")

    expect(described_class.commit_all!(run)).to eq(:committed)
    expect(git(root, "show", "--format=", "--name-only", "HEAD")).to include("existing.txt")
    expect(git(root, "ls-files")).not_to include(".workflow-orchestrator")
    expect(git(root, "status", "--porcelain")).to include(".workflow-orchestrator/")
  ensure
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  it "refuses to publish from the source checkout" do
    root = Dir.mktmpdir
    workspace = Workspace.create!(name: "publication-source-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "publication-source-#{SecureRandom.hex(4)}", task: "Do not publish source", target_root: root,
      launcher_variant: "codex", status: "running", worktree_name: "source-a1b2", source_root: root,
      branch_name: "workflow/source-a1b2"
    )

    expect { described_class.publish!(run) }.to raise_error(Orchestrator::RunPublication::Error, /source checkout/)
    expect(run.reload.publication_status).to eq("failed")
  ensure
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  it "posts each question as a marked PR comment" do
    root = Dir.mktmpdir
    workspace = Workspace.create!(name: "question-publication-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "question-publication-#{SecureRandom.hex(4)}", task: "Ask on GitHub", target_root: root,
      launcher_variant: "codex", status: "running", worktree_name: "question-publication-a1b2",
      branch_name: "workflow/question-publication-a1b2"
    )
    question = UserQuestion.create!(run_id: run.run_id, asked_by: "worker", scope: "config", text: "Choose a setting?", priority: "blocking")
    allow(described_class).to receive(:ensure_conversation_pr!).and_return("https://github.com/example/repo/pull/42")
    allow(described_class).to receive(:validated_root!).and_return(Pathname(root))
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).and_return([ { id: 123, html_url: "https://github.com/example/repo/pull/42#issuecomment-123" }.to_json, "", status ])

    expect(described_class.publish_question!(question)).to eq(:published)
    expect(question.reload).to have_attributes(
      github_comment_id: "123", github_comment_url: "https://github.com/example/repo/pull/42#issuecomment-123"
    )
    expect(Open3).to have_received(:capture3).with(*a_string_starting_with("gh"), any_args)
  ensure
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  it "states that no review evidence was uploaded without listing local artifacts" do
    section = described_class.send(:review_assets_section, [])

    expect(section).to eq("## Review evidence\n\nNo review assets were selected for upload.")
    expect(section).not_to include("run-summary.md")
  end

  it "treats an already ready PR as an idempotent publication result" do
    workspace = Workspace.create!(name: "publication-ready-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "publication-ready-#{SecureRandom.hex(4)}", task: "Avoid duplicate publication",
      target_root: workspace.root_path, launcher_variant: "codex", worktree_name: "ready-a1b2",
      branch_name: "workflow/ready-a1b2", publication_status: "awaiting_approval",
      conversation_pr_status: "ready", pull_request_url: "https://github.com/example/repo/pull/42"
    )

    expect(described_class.publish!(run)).to eq(:published)
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
  end

  it "fills in the real body of a PR that was opened early as a draft, exactly once" do
    root = Dir.mktmpdir
    workspace = Workspace.create!(name: "publication-draft-body-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "publication-draft-body-#{SecureRandom.hex(4)}", task: "Finalize an early draft PR",
      target_root: root, launcher_variant: "codex", worktree_name: "draft-body-a1b2",
      branch_name: "workflow/draft-body-a1b2", publication_status: "committed",
      conversation_pr_status: "draft", pull_request_url: "https://github.com/example/repo/pull/42"
    )
    Orchestrator::ArtifactStore.write(root, run.run_id, "run-summary.md", "## Result\n\nEverything verified.")
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).and_return([ "", "", status ])
    allow(Open3).to receive(:capture3).with("gh", "pr", "list", "--head", run.branch_name, "--state", "open", "--json", "url", "--jq", ".[0].url", chdir: root)
      .and_return([ run.pull_request_url, "", status ])

    expect(described_class.publish!(run)).to eq(:published)

    expect(Open3).to have_received(:capture3).with(
      "gh", "pr", "edit", run.pull_request_url, "--body", a_string_including("Everything verified."), chdir: root
    )
    expect(Open3).to have_received(:capture3).with("gh", "pr", "ready", run.pull_request_url, chdir: root)
    expect(run.reload.conversation_pr_status).to eq("ready")
  ensure
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  it "posts a rerun's summary as a new PR comment instead of overwriting an already-ready body" do
    root = Dir.mktmpdir
    workspace = Workspace.create!(name: "publication-no-clobber-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "publication-no-clobber-#{SecureRandom.hex(4)}", task: "Finalize a second time",
      target_root: root, launcher_variant: "codex", worktree_name: "no-clobber-a1b2",
      branch_name: "workflow/no-clobber-a1b2", publication_status: "committed",
      conversation_pr_status: "ready", pull_request_url: "https://github.com/example/repo/pull/42"
    )
    Orchestrator::ArtifactStore.write(root, run.run_id, "run-summary.md", "## Result\n\nRerun addressed the feedback.")
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).and_return([ "", "", status ])
    allow(Open3).to receive(:capture3).with("gh", "pr", "list", "--head", run.branch_name, "--state", "open", "--json", "url", "--jq", ".[0].url", chdir: root)
      .and_return([ run.pull_request_url, "", status ])
    allow(Open3).to receive(:capture3).with(
      "gh", "api", "--method", "POST", "repos/example/repo/issues/42/comments", "-f",
      a_string_matching(/\Abody=.*Rerun addressed the feedback/m), chdir: root
    ).and_return([ { id: 99, html_url: "https://github.com/example/repo/pull/42#issuecomment-99" }.to_json, "", status ])

    expect(described_class.publish!(run)).to eq(:published)

    expect(Open3).to have_received(:capture3).with(
      "gh", "api", "--method", "POST", "repos/example/repo/issues/42/comments", "-f", any_args, chdir: root
    )
    expect(Open3).not_to have_received(:capture3).with("gh", "pr", "edit", any_args)
    expect(Open3).not_to have_received(:capture3).with("gh", "pr", "ready", any_args)
  ensure
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  it "does not let a missing historical worktree raise during merge detection" do
    workspace = Workspace.create!(name: "publication-missing-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = workspace.runs.create!(
      run_id: "publication-missing-#{SecureRandom.hex(4)}", task: "Skip missing worktree",
      target_root: File.join(workspace.root_path, "missing"), launcher_variant: "codex", worktree_name: "missing-a1b2",
      branch_name: "workflow/missing-a1b2", pull_request_url: "https://github.com/example/repo/pull/42"
    )

    expect(described_class.merged?(run)).to be(false)
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
  end

  it "removes the exact run worktree after GitHub has merged the PR" do
    source_root = Dir.mktmpdir
    worktree_root = Dir.mktmpdir
    FileUtils.remove_entry(worktree_root)
    git(source_root, "init")
    git(source_root, "config", "user.name", "Workflow Orchestrator")
    git(source_root, "config", "user.email", "workflow@example.test")
    File.write(File.join(source_root, "README.md"), "source\n")
    git(source_root, "add", "README.md")
    git(source_root, "commit", "-m", "Initial commit")
    git(source_root, "branch", "-M", "main")
    git(source_root, "remote", "add", "origin", source_root)
    git(source_root, "worktree", "add", "-b", "workflow/merged-a1b2", worktree_root)
    workspace = Workspace.create!(name: "publication-cleanup-#{SecureRandom.hex(4)}", root_path: source_root)
    run = workspace.runs.create!(
      run_id: "publication-cleanup-#{SecureRandom.hex(4)}", task: "Clean merged run",
      target_root: worktree_root, source_root:, launcher_variant: "codex", worktree_name: "merged-a1b2",
      branch_name: "workflow/merged-a1b2", publication_status: "awaiting_approval"
    )

    expect(described_class.cleanup_merged_run!(run)).to eq(:merged)
    expect(File).not_to exist(worktree_root)
    expect(run.reload.publication_status).to eq("merged")
  ensure
    FileUtils.remove_entry(source_root) if source_root && File.exist?(source_root)
  end

  def git(root, *args)
    output, error, status = Open3.capture3("git", "-C", root, *args)
    raise "git #{args.join(' ')} failed: #{error}" unless status.success?

    output
  end
end

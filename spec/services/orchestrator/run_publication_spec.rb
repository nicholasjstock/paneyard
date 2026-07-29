require "rails_helper"

RSpec.describe Orchestrator::RunPublication do
  describe ".queue_worker!" do
    it "spawns a git-role SpawnRequest and marks the run commit_pending" do
      workspace = Workspace.create!(name: "publication-queue-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
      run = workspace.runs.create!(
        run_id: "publication-queue-#{SecureRandom.hex(4)}", task: "Finalize the run", target_root: workspace.root_path,
        launcher_variant: "codex", status: "running", worktree_name: "queue-a1b2", branch_name: "workflow/queue-a1b2"
      )

      described_class.queue_worker!(run)

      expect(run.reload.publication_status).to eq("commit_pending")
      request = SpawnRequest.find_by(run_id: run.run_id, requested_role: "git")
      expect(request).to have_attributes(write_scope: "git_managed", allowed_paths: [ "**/*" ], model_tier: "small", status: "open")
    ensure
      FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
    end

    it "does not spawn a second request while one is already open" do
      workspace = Workspace.create!(name: "publication-queue-dup-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
      run = workspace.runs.create!(
        run_id: "publication-queue-dup-#{SecureRandom.hex(4)}", task: "Finalize the run", target_root: workspace.root_path,
        launcher_variant: "codex", status: "running", worktree_name: "queue-dup-a1b2", branch_name: "workflow/queue-dup-a1b2"
      )

      described_class.queue_worker!(run)
      described_class.queue_worker!(run)

      expect(SpawnRequest.where(run_id: run.run_id, requested_role: "git").count).to eq(1)
    ensure
      FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
    end

    # Regression: run-20260727-165215-d272 failed GitWorktree.provision! (a
    # dirty source checkout) before ever setting branch_name/a real target_root
    # -- but worktree_name was already assigned at run creation, so
    # publication_retryable? still read true. Without this guard,
    # queue_worker! would spawn the git role's full .git write access
    # directly against whatever target_root happens to be, which for an
    # unprovisioned run is the plain source checkout, not an isolated worktree.
    it "refuses to spawn the git worker against a run whose worktree was never actually provisioned" do
      workspace = Workspace.create!(name: "publication-unprovisioned-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
      run = workspace.runs.create!(
        run_id: "publication-unprovisioned-#{SecureRandom.hex(4)}", task: "Never provisioned",
        target_root: workspace.root_path, launcher_variant: "codex", status: "failed",
        worktree_name: "never-provisioned-a1b2", branch_name: nil, publication_status: "failed"
      )

      expect { described_class.queue_worker!(run) }.to raise_error(Orchestrator::RunPublication::Error, /no publication branch/)
      expect(SpawnRequest.where(run_id: run.run_id, requested_role: "git")).to be_empty
    ensure
      FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
    end

    it "refuses to spawn the git worker directly against the source checkout" do
      workspace = Workspace.create!(name: "publication-same-root-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
      run = workspace.runs.create!(
        run_id: "publication-same-root-#{SecureRandom.hex(4)}", task: "Target equals source",
        target_root: workspace.root_path, source_root: workspace.root_path, launcher_variant: "codex",
        status: "failed", worktree_name: "same-root-a1b2", branch_name: "workflow/same-root-a1b2",
        publication_status: "failed"
      )

      expect { described_class.queue_worker!(run) }.to raise_error(Orchestrator::RunPublication::Error, /source checkout/)
      expect(SpawnRequest.where(run_id: run.run_id, requested_role: "git")).to be_empty
    ensure
      FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
    end
  end

  describe ".finalize!" do
    it "creates the pull request in Rails from the reporter summary after the git worker pushes" do
      root = Dir.mktmpdir
      workspace = Workspace.create!(name: "publication-rails-pr-#{SecureRandom.hex(4)}", root_path: root)
      run = workspace.runs.create!(
        run_id: "publication-rails-pr-#{SecureRandom.hex(4)}", task: "Publish a readable pull request",
        target_root: root, launcher_variant: "codex", status: "running", worktree_name: "rails-pr-a1b2",
        branch_name: "workflow/rails-pr-a1b2"
      )
      Orchestrator::ArtifactStore.write(root, run.run_id, "run-summary.md", "# Summary\n\nA real Markdown body.")
      missing_status = instance_double(Process::Status, success?: false)
      success_status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).with(
        anything, "gh", "pr", "view", "workflow/rails-pr-a1b2", "--json", "url,isDraft", chdir: root
      ).and_return([ "", "", missing_status ])
      allow(Open3).to receive(:capture3).with(
        anything, "gh", "pr", "create", "--base", "main", "--head", "workflow/rails-pr-a1b2",
        "--title", "Publish a readable pull request", "--body", "# Summary\n\nA real Markdown body.", chdir: root
      ).and_return([ "https://github.com/example/repo/pull/42\n", "", success_status ])

      described_class.finalize!(run, outcome: "published")

      expect(run.reload.pull_request_url).to eq("https://github.com/example/repo/pull/42")
      expect(Open3).to have_received(:capture3).with(
        anything, "gh", "pr", "create", "--base", "main", "--head", "workflow/rails-pr-a1b2",
        "--title", "Publish a readable pull request", "--body", "# Summary\n\nA real Markdown body.", chdir: root
      )
    ensure
      FileUtils.remove_entry(root) if root && File.exist?(root)
    end

    it "uploads curator-selected review assets from Rails before opening the PR" do
      root = Dir.mktmpdir
      workspace = Workspace.create!(name: "publication-rails-assets-#{SecureRandom.hex(4)}", root_path: root)
      run = workspace.runs.create!(
        run_id: "publication-rails-assets-#{SecureRandom.hex(4)}", task: "Publish evidence", target_root: root,
        launcher_variant: "codex", status: "running", worktree_name: "rails-assets-a1b2",
        branch_name: "workflow/rails-assets-a1b2"
      )
      File.binwrite(File.join(root, "demo.png"), "image")
      asset = run.review_assets.create!(workspace_path: "demo.png", label: "Demo image")
      missing_status = instance_double(Process::Status, success?: false)
      success_status = instance_double(Process::Status, success?: true)
      tag = "workflow-evidence-#{run.run_id}"
      allow(Open3).to receive(:capture3).with(
        anything, "gh", "release", "view", tag, "--json", "url", chdir: root
      ).and_return([ "", "", missing_status ])
      allow(Open3).to receive(:capture3).with(
        anything, "gh", "release", "create", tag, "--draft", "--target", "workflow/rails-assets-a1b2", File.join(root, "demo.png"), chdir: root
      ).and_return([ "", "", success_status ])
      allow(Open3).to receive(:capture3).with(
        anything, "gh", "release", "view", tag, "--json", "assets", chdir: root
      ).and_return([ { assets: [ { name: "demo.png", url: "https://github.com/example/repo/releases/download/#{tag}/demo.png" } ] }.to_json, "", success_status ])

      run.update!(pull_request_url: "https://github.com/example/repo/pull/42")
      described_class.finalize!(run, outcome: "published")

      expect(asset.reload.github_url).to eq("https://github.com/example/repo/releases/download/#{tag}/demo.png")
      expect(Open3).to have_received(:capture3).with(
        anything, "gh", "release", "create", tag, "--draft", "--target", "workflow/rails-assets-a1b2", File.join(root, "demo.png"), chdir: root
      )
    ensure
      FileUtils.remove_entry(root) if root && File.exist?(root)
    end

    it "makes a pre-existing draft PR ready with the reporter summary from Rails" do
      root = Dir.mktmpdir
      workspace = Workspace.create!(name: "publication-rails-draft-#{SecureRandom.hex(4)}", root_path: root)
      run = workspace.runs.create!(
        run_id: "publication-rails-draft-#{SecureRandom.hex(4)}", task: "Finish the draft", target_root: root,
        launcher_variant: "codex", status: "running", worktree_name: "rails-draft-a1b2",
        branch_name: "workflow/rails-draft-a1b2"
      )
      Orchestrator::ArtifactStore.write(root, run.run_id, "run-summary.md", "# Final summary")
      status = instance_double(Process::Status, success?: true)
      url = "https://github.com/example/repo/pull/42"
      allow(Open3).to receive(:capture3).with(
        anything, "gh", "pr", "view", "workflow/rails-draft-a1b2", "--json", "url,isDraft", chdir: root
      ).and_return([ { url:, isDraft: true }.to_json, "", status ])
      allow(Open3).to receive(:capture3).with(anything, "gh", "pr", "edit", url, "--body", "# Final summary", chdir: root)
        .and_return([ "", "", status ])
      allow(Open3).to receive(:capture3).with(anything, "gh", "pr", "ready", url, chdir: root)
        .and_return([ "", "", status ])

      described_class.finalize!(run, outcome: "published")

      expect(run.reload.pull_request_url).to eq(url)
      expect(Open3).to have_received(:capture3).with(anything, "gh", "pr", "ready", url, chdir: root)
    ensure
      FileUtils.remove_entry(root) if root && File.exist?(root)
    end

    it "persists a no_changes outcome as completed without opening a review question" do
      workspace = Workspace.create!(name: "publication-nochange-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
      run = workspace.runs.create!(
        run_id: "publication-nochange-#{SecureRandom.hex(4)}", task: "Nothing to publish", target_root: workspace.root_path,
        launcher_variant: "codex", status: "running", worktree_name: "nochange-a1b2", branch_name: "workflow/nochange-a1b2"
      )

      expect(described_class.finalize!(run, outcome: "no_changes")).to eq(:no_changes)
      expect(run.reload).to have_attributes(publication_status: "no_changes", status: "completed")
      expect(run.open_blocking_question?).to be(false)
    ensure
      FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
    end

    it "persists a failed outcome with the reported error" do
      workspace = Workspace.create!(name: "publication-failed-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
      run = workspace.runs.create!(
        run_id: "publication-failed-#{SecureRandom.hex(4)}", task: "Fails to publish", target_root: workspace.root_path,
        launcher_variant: "codex", status: "running", worktree_name: "failed-a1b2", branch_name: "workflow/failed-a1b2"
      )

      expect(described_class.finalize!(run, outcome: "failed", error: "push rejected")).to eq(:failed)
      expect(run.reload).to have_attributes(publication_status: "failed", publication_error: "push rejected", status: "failed")
    ensure
      FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
    end

    it "rejects an unknown outcome" do
      workspace = Workspace.create!(name: "publication-unknown-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
      run = workspace.runs.create!(
        run_id: "publication-unknown-#{SecureRandom.hex(4)}", task: "Bad outcome", target_root: workspace.root_path,
        launcher_variant: "codex", status: "running", worktree_name: "unknown-a1b2", branch_name: "workflow/unknown-a1b2"
      )

      expect { described_class.finalize!(run, outcome: "bogus") }.to raise_error(Orchestrator::RunPublication::Error, /Unknown publication outcome/)
    ensure
      FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
    end
  end

  it "opens an issue and posts a question there when the run has no PR yet" do
    root = Dir.mktmpdir
    workspace = Workspace.create!(name: "question-publication-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "question-publication-#{SecureRandom.hex(4)}", task: "Ask on GitHub", target_root: root,
      launcher_variant: "codex", status: "running", worktree_name: "question-publication-a1b2",
      branch_name: "workflow/question-publication-a1b2"
    )
    question = UserQuestion.create!(run_id: run.run_id, asked_by: "worker", scope: "config", text: "Choose a setting?", priority: "blocking")
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).with(anything, "gh", "issue", "create", any_args)
      .and_return([ "https://github.com/example/repo/issues/9\n", "", status ])
    allow(Open3).to receive(:capture3).with(anything, "gh", "api", any_args)
      .and_return([ { id: 123, html_url: "https://github.com/example/repo/issues/9#issuecomment-123" }.to_json, "", status ])

    expect(described_class.publish_question!(question)).to eq(:published)
    expect(question.reload).to have_attributes(
      github_comment_id: "123", github_comment_url: "https://github.com/example/repo/issues/9#issuecomment-123"
    )
    expect(run.reload).to have_attributes(github_issue_url: "https://github.com/example/repo/issues/9", github_issue_status: "open")
    expect(Open3).to have_received(:capture3).with(anything, "gh", "issue", "create", any_args)
  ensure
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  it "posts a question directly to the PR without opening an issue once one already exists" do
    root = Dir.mktmpdir
    workspace = Workspace.create!(name: "question-publication-pr-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "question-publication-pr-#{SecureRandom.hex(4)}", task: "Ask on GitHub", target_root: root,
      launcher_variant: "codex", status: "running", worktree_name: "question-publication-pr-a1b2",
      branch_name: "workflow/question-publication-pr-a1b2", pull_request_url: "https://github.com/example/repo/pull/42"
    )
    question = UserQuestion.create!(run_id: run.run_id, asked_by: "worker", scope: "config", text: "Choose a setting?", priority: "blocking")
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).and_return([ { id: 123, html_url: "https://github.com/example/repo/pull/42#issuecomment-123" }.to_json, "", status ])

    expect(described_class.publish_question!(question)).to eq(:published)
    expect(run.reload.github_issue_url).to be_nil
    expect(Open3).not_to have_received(:capture3).with(anything, "gh", "issue", "create", any_args)
  ensure
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  it "links the conversation issue from the real PR and leaves it open until merge" do
    root = Dir.mktmpdir
    workspace = Workspace.create!(name: "publication-close-issue-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "publication-close-issue-#{SecureRandom.hex(4)}", task: "Finalize with an open issue", target_root: root,
      launcher_variant: "codex", status: "running", worktree_name: "close-issue-a1b2", branch_name: "workflow/close-issue-a1b2",
      github_issue_url: "https://github.com/example/repo/issues/9", github_issue_status: "open",
      pull_request_url: "https://github.com/example/repo/pull/42"
    )
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).with(anything, "gh", "pr", "view", "https://github.com/example/repo/pull/42", "--json", "body", chdir: root)
      .and_return([ { body: "# Summary" }.to_json, "", status ])
    allow(Open3).to receive(:capture3).with(anything, "gh", "pr", "edit", "https://github.com/example/repo/pull/42", "--body", "# Summary\n\nCloses #9", chdir: root)
      .and_return([ "", "", status ])

    described_class.finalize!(run, outcome: "published")

    expect(run.reload.github_issue_status).to eq("open")
    expect(Open3).to have_received(:capture3).with(
      anything, "gh", "pr", "edit", "https://github.com/example/repo/pull/42", "--body", "# Summary\n\nCloses #9", chdir: root
    )
  ensure
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  it "does not attempt to close an issue when the run never opened one" do
    root = Dir.mktmpdir
    workspace = Workspace.create!(name: "publication-no-issue-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "publication-no-issue-#{SecureRandom.hex(4)}", task: "Finalize with no issue", target_root: root,
      launcher_variant: "codex", status: "running", worktree_name: "no-issue-a1b2", branch_name: "workflow/no-issue-a1b2"
    )

    run.update!(pull_request_url: "https://github.com/example/repo/pull/42")
    described_class.finalize!(run, outcome: "published")

    expect(run.reload.github_issue_status).to be_nil
  ensure
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  it "includes GH_TOKEN in gh CLI invocations when GitHub App is configured" do
    root = Dir.mktmpdir
    workspace = Workspace.create!(name: "gh-token-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "gh-token-#{SecureRandom.hex(4)}", task: "Create issue with GitHub App", target_root: root,
      launcher_variant: "codex", status: "running", worktree_name: "test-a1b2", branch_name: "workflow/test-a1b2"
    )

    allow(Orchestrator::GitHubAppAuth).to receive(:app_configured?).and_return(true)
    allow(Orchestrator::GitHubAppAuth).to receive(:installation_token_for)
      .with(workspace_root: root).and_return("ghu_test_token")

    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).with(
      { "GH_TOKEN" => "ghu_test_token" }, "gh", "issue", "create",
      "--title", anything, "--body", anything, chdir: root
    ).and_return([ "https://github.com/example/repo/issues/9\n", "", status ])

    result = described_class.send(:create_issue, Pathname(root), run)
    expect(result).to eq("https://github.com/example/repo/issues/9")
    expect(Open3).to have_received(:capture3).with(hash_including("GH_TOKEN" => "ghu_test_token"), any_args)
  ensure
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  it "passes empty environment hash when GitHub App is not configured" do
    root = Dir.mktmpdir
    workspace = Workspace.create!(name: "no-gh-token-#{SecureRandom.hex(4)}", root_path: root)
    run = workspace.runs.create!(
      run_id: "no-gh-token-#{SecureRandom.hex(4)}", task: "Create issue without GitHub App", target_root: root,
      launcher_variant: "codex", status: "running", worktree_name: "test-a1b2", branch_name: "workflow/test-a1b2"
    )

    allow(Orchestrator::GitHubAppAuth).to receive(:app_configured?).and_return(false)

    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).with(
      {}, "gh", "issue", "create", "--title", anything, "--body", anything, chdir: root
    ).and_return([ "https://github.com/example/repo/issues/9\n", "", status ])

    result = described_class.send(:create_issue, Pathname(root), run)
    expect(result).to eq("https://github.com/example/repo/issues/9")
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
    # Merged-run cleanup must not synchronize the shared source checkout.
    # A normal local edit must not prevent removal of this independent
    # worktree; the old cleanup-time rebase incorrectly made it do so.
    File.write(File.join(source_root, "README.md"), "source with a local edit\n")
    workspace = Workspace.create!(name: "publication-cleanup-#{SecureRandom.hex(4)}", root_path: source_root)
    run = workspace.runs.create!(
      run_id: "publication-cleanup-#{SecureRandom.hex(4)}", task: "Clean merged run",
      target_root: worktree_root, source_root:, launcher_variant: "codex", worktree_name: "merged-a1b2",
      branch_name: "workflow/merged-a1b2", publication_status: "awaiting_approval",
      github_issue_url: "https://github.com/example/repo/issues/9", github_issue_status: "open"
    )
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).and_call_original
    allow(Open3).to receive(:capture3).with(
      anything, "gh", "issue", "close", "https://github.com/example/repo/issues/9", "--comment", "Merged in ", chdir: worktree_root
    ).and_return([ "", "", status ])

    expect(described_class.cleanup_merged_run!(run)).to eq(:merged)
    expect(File).not_to exist(worktree_root)
    expect(run.reload).to have_attributes(publication_status: "merged", github_issue_status: "closed")
  ensure
    FileUtils.remove_entry(source_root) if source_root && File.exist?(source_root)
  end

  def git(root, *args)
    output, error, status = Open3.capture3("git", "-C", root, *args)
    raise "git #{args.join(' ')} failed: #{error}" unless status.success?

    output
  end
end

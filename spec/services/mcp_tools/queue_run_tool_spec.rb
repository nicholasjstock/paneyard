require "rails_helper"

RSpec.describe McpTools::QueueRunTool do
  # A real repository: the base branch is checked before anything is queued.
  let(:repository) { create_source_checkout(branches: [ "feature/payments" ]) }

  it "queues a run in an explicitly named workspace, from its default base branch, with no run session behind the call" do
    workspace = create_workspace(prefix: "queue-run-explicit", repository_path: repository)

    response = described_class.call(task: "Fix the flaky spec.", workspace: workspace.name, server_context: {})

    expect(response.error?).to be_falsey
    expect(response.structured_content).to include(baseBranch: "main")
    run = workspace.runs.sole
    expect(run).to have_attributes(task: "Fix the flaky spec.", status: "queued", launcher_variant: "claude", launched_by: "mcp",
      base_branch: "main", target_root: repository)
  end

  it "queues a run from the base branch the caller names, whatever the repository has checked out" do
    workspace = create_workspace(prefix: "queue-run-branch", repository_path: repository, default_base_branch: "main")
    system("git", "-C", repository, "switch", "-q", "-c", "unrelated", exception: true)

    response = described_class.call(task: "Pay.", workspace: workspace.name, baseBranch: "feature/payments", server_context: {})

    expect(response.structured_content).to include(baseBranch: "feature/payments")
    expect(workspace.runs.sole.base_branch).to eq("feature/payments")
  end

  it "queues the driver and model the caller names, and says which it queued" do
    workspace = create_workspace(prefix: "queue-run-model", repository_path: repository)

    response = described_class.call(task: "Model.", workspace: workspace.name, driver: "codex", model: "gpt-5.5", server_context: {})

    expect(response.structured_content).to include(driver: "codex", model: "gpt-5.5")
    expect(workspace.runs.sole).to have_attributes(launcher_variant: "codex", model: "gpt-5.5")
  end

  it "refuses a model id that could pass for a flag, queueing nothing" do
    workspace = create_workspace(prefix: "queue-run-bad-model", repository_path: repository)

    response = described_class.call(task: "Model.", workspace: workspace.name, model: "--yolo", server_context: {})

    expect(response.error?).to be(true)
    expect(workspace.runs).to be_empty
  end

  it "uses the workspace's default base branch when it is not main" do
    system("git", "-C", repository, "branch", "develop", exception: true)
    workspace = create_workspace(prefix: "queue-run-develop", repository_path: repository, default_base_branch: "develop")

    described_class.call(task: "Dev.", workspace: workspace.name, server_context: {})

    expect(workspace.runs.sole.base_branch).to eq("develop")
  end

  it "refuses a base branch the repository does not have, queueing nothing" do
    workspace = create_workspace(prefix: "queue-run-missing", repository_path: repository)

    response = described_class.call(task: "Nope.", workspace: workspace.name, baseBranch: "feature/missing", server_context: {})

    expect(response.error?).to be(true)
    expect(response.structured_content).to include(error: "base_branch_invalid")
    expect(response.structured_content[:message]).to include("Base branch `feature/missing`", "no local branch")
    expect(workspace.runs).to be_empty
  end

  it "defaults to the calling run session's own workspace" do
    run, session = create_run_and_session(run: create_run(workspace: create_workspace(repository_path: repository)))

    described_class.call(task: "Follow-up work.", server_context: { run_session_id: session.id })

    expect(run.workspace.runs.find_by(task: "Follow-up work.")).to be_present
  end

  # An agent opened in a repository nobody registered must not have its job
  # land in whichever workspace happens to be oldest.
  it "requires a workspace from outside a run, even when only one is registered, and points at register_workspace" do
    only = create_workspace(prefix: "queue-run-only")

    response = described_class.call(task: "Do something here.", server_context: {})

    expect(response.error?).to be(true)
    expect(response.structured_content[:message]).to include(
      "workspace is required", "#{only.name} (#{only.repository_path})", "register_workspace"
    )
    expect(only.runs).to be_empty
  end

  it "says no workspace is registered yet, and how to register one" do
    response = described_class.call(task: "Do something here.", server_context: {})

    expect(response.structured_content[:message]).to include("No workspace is registered yet", "register_workspace")
  end

  it "rejects a blank task" do
    workspace = create_workspace(prefix: "queue-run-blank")

    response = described_class.call(task: "", workspace: workspace.name, server_context: {})

    expect(response.error?).to be(true)
    expect(workspace.runs).to be_empty
  end

  it "errors on an unknown workspace instead of silently picking a default" do
    response = described_class.call(task: "Do something.", workspace: "no-such-workspace", server_context: {})

    expect(response.error?).to be(true)
  end
end

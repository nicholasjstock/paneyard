require "rails_helper"

RSpec.describe "terminal finalization tools" do
  it "lets a reporter complete only after writing its assigned summary" do
    workspace, run, reporter = finalization_worker("reporter", "run-summary.md")

    response = McpTools::CompleteRunFinalizationTool.call(runId: run.run_id, server_context: { worker_id: reporter.worker_id })
    expect(tool_payload(response).fetch("message")).to include("Write run-summary.md")

    Orchestrator::ArtifactStore.write(run.target_root, run.run_id, reporter.scope, "## Outcome\n\nCompleted.")
    response = McpTools::CompleteRunFinalizationTool.call(runId: run.run_id, server_context: { worker_id: reporter.worker_id })

    expect(tool_payload(response).fetch("outcome")).to eq("completed")
    expect(reporter.reload.handoff_completed_at).to be_present
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
  end

  it "rejects workflow runtime files and accepts a real untracked reviewer asset" do
    workspace, run, curator = finalization_worker("curator", "review-assets.md")
    runtime_asset = File.join(Orchestrator::ArtifactStore.output_dir(run.target_root), "workers", "trace.log")
    FileUtils.mkdir_p(File.dirname(runtime_asset))
    File.write(runtime_asset, "not reviewer evidence")
    review_asset = File.join(run.target_root, "demo.mp4")
    File.binwrite(review_asset, "video")

    rejected = McpTools::SelectReviewAssetsTool.call(runId: run.run_id, assets: [ { path: runtime_asset.delete_prefix("#{run.target_root}/"), label: "Trace" } ], server_context: { worker_id: curator.worker_id })
    accepted = McpTools::SelectReviewAssetsTool.call(runId: run.run_id, assets: [ { path: "demo.mp4", label: "Demo video" } ], server_context: { worker_id: curator.worker_id })

    expect(tool_payload(rejected).fetch("message")).to include("workflow runtime")
    expect(tool_payload(accepted).fetch("assets")).to eq([ { "workspacePath" => "demo.mp4", "label" => "Demo video" } ])
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
  end

  it "lets a demo worker complete and persists an optional clickPath" do
    workspace, run, demo = finalization_worker("demo", "demo-notes.md")
    Orchestrator::ArtifactStore.write(run.target_root, run.run_id, demo.scope, "Started the dev server on the default port.")

    response = McpTools::CompleteRunFinalizationTool.call(
      runId: run.run_id, clickPath: "Open /schedule and click Publish.", server_context: { worker_id: demo.worker_id }
    )

    expect(tool_payload(response).fetch("outcome")).to eq("completed")
    expect(demo.reload.handoff_completed_at).to be_present
    expect(demo.reload.click_path).to eq("Open /schedule and click Publish.")
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
  end

  it "rejects complete_run_finalization from a role outside reporter, curator, or demo" do
    workspace, run, committer = finalization_worker("committer", "commit-worktree.md")

    response = McpTools::CompleteRunFinalizationTool.call(runId: run.run_id, server_context: { worker_id: committer.worker_id })

    expect(tool_payload(response).fetch("message")).to include("reporter, curator, or demo")
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
  end

  it "accepts an explicit empty curator selection" do
    workspace, run, curator = finalization_worker("curator", "review-assets.md")

    response = McpTools::SelectReviewAssetsTool.call(runId: run.run_id, assets: [], server_context: { worker_id: curator.worker_id })

    expect(tool_payload(response).fetch("assets")).to eq([])
    expect(run.review_assets).to be_empty
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
  end

  def finalization_worker(role, scope)
    workspace = Workspace.create!(name: "finalize-tools-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(workspace:, run_id: "finalize-tools-#{SecureRandom.hex(4)}", task: "Finish a run", target_root: workspace.root_path, launcher_variant: "codex")
    worker = run.workers.create!(worker_id: SecureRandom.uuid, role:, nickname: role, reason: "Finish.", scope:, status: "running", pid: 123_456, command: "codex", args: [], prompt_path: "prompt", log_path: "log", last_message_path: "last", env_path: "env")
    [ workspace, run, worker ]
  end

  def tool_payload(response)
    JSON.parse(response.content.first[:text])
  end
end

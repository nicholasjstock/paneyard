require "rails_helper"

RSpec.describe "launch artifact manifests" do
  def workspace
    Workspace.create!(name: "launch-artifacts-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir, protected_path_patterns: [ "app/**/*.rb" ])
  end

  it "persists multiple selected artifacts with their originating locations" do
    ws = workspace
    run = ws.runs.create!(run_id: "launch-#{SecureRandom.hex(4)}", task: "Inspect files", target_root: ws.source_root,
      launcher_variant: "codex", status: "launching", launch_artifacts: [
        { name: "production.sqlite3", source_path: "/var/lib/app/production.sqlite3", source_run_id: "source-run" },
        { name: "trace.log", source_path: "/tmp/trace.log", source_run_id: "source-run" }
      ])

    expect(run.reload.launch_artifacts).to include(
      hash_including("name" => "production.sqlite3", "source_path" => "/var/lib/app/production.sqlite3"),
      hash_including("name" => "trace.log", "source_path" => "/tmp/trace.log")
    )
  end

  it "exposes the manifest and source run in a worker prompt" do
    ws = workspace
    root = ws.source_root
    FileUtils.mkdir_p(root)
    source = ws.runs.create!(run_id: "source-#{SecureRandom.hex(4)}", task: "Source", target_root: root, launcher_variant: "codex", status: "running",
      launch_artifacts: [ { "name" => "production.sqlite3", "source_path" => "/var/lib/app/production.sqlite3" } ])
    Orchestrator::ArtifactStore.write(root, source.run_id, "production.sqlite3", "sqlite bytes")
    run = ws.runs.create!(run_id: "child-#{SecureRandom.hex(4)}", task: "Child", target_root: Dir.mktmpdir,
      launcher_variant: "codex", status: "running", parent_run: source)
    request = run.spawn_requests.create!(asked_by: "planner", scope: "report.md", text: "Review it.", requested_role: "worker",
      priority: "blocking", inherited_artifacts: [ "production.sqlite3" ])

    prompt = Orchestrator::SpawnRequestedWorkers.send(:build_requested_worker_prompt, run_id: run.run_id, request:, run:)
    expect(prompt).to include("Artifact Manifest", "production.sqlite3", source.run_id)
  end

  it "reads a parent artifact from a child run without copying it" do
    ws = workspace
    source_root = ws.source_root
    FileUtils.mkdir_p(source_root)
    source = ws.runs.create!(run_id: "source-#{SecureRandom.hex(4)}", task: "Source", target_root: source_root, launcher_variant: "codex", status: "running")
    Orchestrator::ArtifactStore.write(source_root, source.run_id, "production.sqlite3", "sqlite bytes")
    child = ws.runs.create!(run_id: "child-#{SecureRandom.hex(4)}", task: "Child", target_root: Dir.mktmpdir,
      launcher_variant: "codex", status: "running", parent_run: source,
      launch_artifacts: [ { "name" => "production.sqlite3", "source_run_id" => source.run_id, "source_path" => source_root } ])

    response = McpTools::ReadWorkflowArtifactTool.call(runId: child.run_id, artifactName: "production.sqlite3",
      inheritFromRunId: source.run_id, server_context: nil)
    expect(response.structured_content[:content]).to eq("sqlite bytes")
    expect(File).not_to exist(Orchestrator::ArtifactStore.resolve_path(child.target_root, child.run_id, "production.sqlite3"))
  end
end

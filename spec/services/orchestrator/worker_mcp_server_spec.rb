require "rails_helper"

RSpec.describe Orchestrator::WorkerMcpServer do
  it "exposes worker-scoped tools without spawn or lifecycle authority" do
    tools = described_class.build(server_context: { worker_id: "worker-id" }).tools.keys

    expect(tools).to include("worker_turn", "write_workflow_artifact")
    expect(tools).not_to include(
      "append_spawn_request", "spawn_worker", "stop_worker", "publish_planner_jobs", "run_guarded_command"
    )
  end

  it "exposes terminal tools only to the matching terminal role" do
    workspace = Workspace.create!(name: "mcp-tools-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    run = Run.create!(workspace:, run_id: "mcp-tools-#{SecureRandom.hex(4)}", task: "Scope terminal tools", target_root: workspace.root_path, launcher_variant: "codex")
    reporter = run.workers.create!(worker_id: SecureRandom.uuid, role: "reporter", nickname: "reporter", reason: "Report.", scope: "run-summary.md", status: "running", pid: 123_456, command: "codex", args: [], prompt_path: "prompt", log_path: "log", last_message_path: "last", env_path: "env")
    curator = run.workers.create!(worker_id: SecureRandom.uuid, role: "curator", nickname: "curator", reason: "Curate.", scope: "review-assets.md", status: "running", pid: 123_457, command: "codex", args: [], prompt_path: "prompt", log_path: "log", last_message_path: "last", env_path: "env")
    demo = run.workers.create!(worker_id: SecureRandom.uuid, role: "demo", nickname: "demo", reason: "Demo.", scope: "demo-notes.md", status: "running", pid: 123_458, command: "codex", args: [], prompt_path: "prompt", log_path: "log", last_message_path: "last", env_path: "env")
    seeder = run.workers.create!(worker_id: SecureRandom.uuid, role: "seeder", nickname: "seeder", reason: "Seed.", scope: "seed-data.md", status: "running", pid: 123_459, command: "codex", args: [], prompt_path: "prompt", log_path: "log", last_message_path: "last", env_path: "env")
    git_worker = run.workers.create!(worker_id: SecureRandom.uuid, role: "git", nickname: "git", reason: "Publish.", scope: "publish-x.md", status: "running", pid: 123_460, command: "codex", args: [], prompt_path: "prompt", log_path: "log", last_message_path: "last", env_path: "env", write_scope: "git_managed", allowed_paths: [ "**/*" ])

    reporter_tools = described_class.build(server_context: { worker_id: reporter.worker_id }).tools.keys
    curator_tools = described_class.build(server_context: { worker_id: curator.worker_id }).tools.keys
    demo_tools = described_class.build(server_context: { worker_id: demo.worker_id }).tools.keys
    seeder_tools = described_class.build(server_context: { worker_id: seeder.worker_id }).tools.keys
    git_tools = described_class.build(server_context: { worker_id: git_worker.worker_id }).tools.keys

    expect(reporter_tools).to include("get_reporter_context", "complete_worker_task")
    expect(reporter_tools).not_to include("select_review_assets", "finalize_run_publication", "worker_turn", "start_run_command")
    expect(curator_tools).to include("select_review_assets", "complete_worker_task")
    expect(curator_tools).not_to include("get_reporter_context", "finalize_run_publication", "worker_turn", "start_run_command")
    expect(demo_tools).to include("start_run_command", "stop_run_command", "complete_worker_task", "worker_turn")
    expect(demo_tools).not_to include("get_reporter_context", "select_review_assets", "finalize_run_publication")
    expect(seeder_tools).to include("write_scoped_file", "get_run_context", "complete_worker_task")
    expect(seeder_tools).not_to include("get_reporter_context", "select_review_assets", "finalize_run_publication", "worker_turn", "start_run_command")
    expect(git_tools).to include("finalize_run_publication", "worker_turn", "get_run_context", "write_workflow_artifact")
    expect(git_tools).not_to include("get_reporter_context", "select_review_assets", "complete_worker_task", "start_run_command")
  ensure
    FileUtils.remove_entry(workspace.root_path) if workspace && File.exist?(workspace.root_path)
  end
end

require "rails_helper"

RSpec.describe Orchestrator::WorkerSpawner do
  it "extracts diagnosis mode from the planner request used by the spawn path" do
    request = instance_double(
      SpawnRequest, execution_mode: nil,
      text: "Execution mode: diagnosis. Write scope: artifact_only."
    )

    expect(Orchestrator::SpawnRequestedWorkers.execution_mode(request)).to eq("diagnosis")
  end

  describe ".spawn_worker" do
    it "rejects legacy planner process spawns" do
      workspace_root = Dir.mktmpdir("workflow-worker-spawner-claude")
      workspace = Workspace.create!(name: "planner-#{SecureRandom.hex(4)}", root_path: workspace_root)
      run = workspace.runs.create!(
        run_id: "demo-#{SecureRandom.hex(4)}",
        task: "Recover a stalled run",
        target_root: workspace.root_path,
        launcher_variant: "claude",
        status: "running",
        launched_by: "operator",
        started_at: Time.current
      )

      expect(Process).not_to receive(:spawn)
      expect do
        described_class.spawn_worker(
          run: run, role: "planner", nickname: "planner-test", reason: "Recover the run.",
          scope: "workflow-plan.md", prompt: "Inspect the recovery context."
        )
      end.to raise_error(ArgumentError, /Planner processes were removed/)
    end

    it "inlines the Codex persona from this repository instead of depending on target-workspace agent files" do
      workspace_root = Dir.mktmpdir("workflow-worker-spawner-codex")
      workspace = Workspace.create!(name: "planner-#{SecureRandom.hex(4)}", root_path: workspace_root)
      run = workspace.runs.create!(
        run_id: "demo-#{SecureRandom.hex(4)}",
        task: "Complete the worker handoff",
        target_root: workspace.root_path,
        launcher_variant: "codex",
        status: "running",
        launched_by: "operator",
        started_at: Time.current
      )

      allow(Process).to receive(:spawn).and_return(23_456)
      allow(Process).to receive(:detach)
      stdin_read = instance_double(IO, close: true)
      stdin_write = StringIO.new
      allow(IO).to receive(:pipe).and_return([ stdin_read, stdin_write ])

      worker = described_class.spawn_worker(
        run: run,
        role: "worker",
        nickname: "worker-test",
        reason: "Complete the requested task.",
        scope: "fix-summary.md",
        prompt: "Verify the issue and report back."
      )

      expect(worker.command).to eq("codex")
      expect(worker.model).to eq("gpt-5.6-luna")
      expect(worker.args).to include("--model", "gpt-5.6-luna")
      expect(JSON.parse(File.read(worker.env_path)).fetch("WORKER_LOG_PATH")).to eq(worker.log_path)
      expect(File.read(worker.prompt_path)).to include('name = "worker"')
      expect(File.read(worker.prompt_path)).to include("Current task:\nVerify the issue and report back.")
    end

    it "starts Claude diagnosis workers on Haiku" do
      workspace_root = Dir.mktmpdir("workflow-worker-spawner-diagnosis")
      workspace = Workspace.create!(name: "planner-#{SecureRandom.hex(4)}", root_path: workspace_root)
      run = workspace.runs.create!(
        run_id: "demo-#{SecureRandom.hex(4)}", task: "Diagnose an uncertain boundary",
        target_root: workspace.root_path, launcher_variant: "claude", status: "running",
        launched_by: "operator", started_at: Time.current
      )

      allow(Process).to receive(:spawn).and_return(34_567)
      allow(Process).to receive(:detach)

      worker = described_class.spawn_worker(
        run: run, role: "worker", mode: "diagnosis", nickname: "diagnosis-worker",
        reason: "Confirm the runtime boundary.", scope: "diagnosis.md", prompt: "Capture direct evidence."
      )

      expect(worker.model).to eq("haiku")
      expect(worker.args).to include("--model", "haiku")
      expect(File.read(worker.prompt_path)).to include(
        "runId: #{run.run_id}",
        "workerId: #{worker.worker_id}",
        "nickname: diagnosis-worker",
        "scope/artifact: diagnosis.md"
      )
      environment = JSON.parse(File.read(worker.env_path))
      expect(environment).to include(
        "WORKFLOW_RUN_ID" => run.run_id,
        "WORKFLOW_WORKER_ID" => worker.worker_id,
        "WORKFLOW_WORKER_NICKNAME" => "diagnosis-worker",
        "WORKFLOW_WORKER_SCOPE" => "diagnosis.md"
      )
    end

    it "spawns a chaperone worker on a Claude run against the curated MCP override instead of the normal worker MCP config" do
      workspace_root = Dir.mktmpdir("workflow-worker-spawner-chaperone")
      workspace = Workspace.create!(name: "chaperone-#{SecureRandom.hex(4)}", root_path: workspace_root)
      run = workspace.runs.create!(
        run_id: "demo-#{SecureRandom.hex(4)}", task: "Review a repeated failure",
        target_root: workspace.root_path, launcher_variant: "claude", status: "running",
        launched_by: "operator", started_at: Time.current
      )

      allow(Process).to receive(:spawn).and_return(45_678)
      allow(Process).to receive(:detach)

      worker = described_class.spawn_worker(
        run: run, role: "chaperone", nickname: "chaperone-test", reason: "Chaperone review: repeated failure.",
        scope: "diagnose-it", prompt: "You must begin by calling get_chaperone_state.", model_tier: "strong",
        mcp_override: {
          url: "http://127.0.0.1:3000/mcp/chaperone", token: "chaperone-token",
          allowed_tools: %w[get_chaperone_state read_chaperone_artifact submit_chaperone_decision]
        }
      )

      expect(worker.command).to eq("claude")
      expect(worker.model).to eq("sonnet")
      expect(worker.args).to include("--print", "--strict-mcp-config")
      expect(worker.args).not_to include("--tools", "--settings", "--output-format")
      allowed_tools_index = worker.args.index("--allowedTools")
      expect(worker.args[allowed_tools_index + 1]).to eq(
        "mcp__chaperone__get_chaperone_state,mcp__chaperone__read_chaperone_artifact,mcp__chaperone__submit_chaperone_decision"
      )

      mcp_config = JSON.parse(File.read(worker.mcp_config_path))
      expect(mcp_config.dig("mcpServers", "chaperone", "url")).to eq("http://127.0.0.1:3000/mcp/chaperone")
      expect(mcp_config.dig("mcpServers", "chaperone", "headers", "Authorization")).to eq("Bearer chaperone-token")
      claude_settings_path = worker.mcp_config_path.sub(/\.mcp\.json\z/, ".claude-settings.json")
      expect(File.exist?(claude_settings_path)).to be false
    end

    it "spawns a chaperone worker on a Codex run through the codex CLI instead of forcing Claude" do
      workspace_root = Dir.mktmpdir("workflow-worker-spawner-chaperone-codex")
      workspace = Workspace.create!(name: "chaperone-codex-#{SecureRandom.hex(4)}", root_path: workspace_root)
      run = workspace.runs.create!(
        run_id: "demo-#{SecureRandom.hex(4)}", task: "Review a repeated failure",
        target_root: workspace.root_path, launcher_variant: "codex", status: "running",
        launched_by: "operator", started_at: Time.current
      )

      allow(Process).to receive(:spawn).and_return(56_789)
      allow(Process).to receive(:detach)
      stdin_read = instance_double(IO, close: true)
      stdin_write = StringIO.new
      allow(IO).to receive(:pipe).and_return([ stdin_read, stdin_write ])

      worker = described_class.spawn_worker(
        run: run, role: "chaperone", nickname: "chaperone-codex-test", reason: "Chaperone review: repeated failure.",
        scope: "diagnose-it", prompt: "You must begin by calling get_chaperone_state.", model_tier: "strong",
        mcp_override: {
          url: "http://127.0.0.1:3000/mcp/chaperone", token: "chaperone-token",
          allowed_tools: %w[get_chaperone_state read_chaperone_artifact submit_chaperone_decision]
        }
      )

      expect(worker.command).to eq("codex")
      expect(worker.model).to eq("default")
      expect(worker.args).to include("--sandbox", "read-only")
      expect(worker.args).not_to include("--model")
      expect(worker.args).to include(%(mcp_servers.chaperone.url=#{"http://127.0.0.1:3000/mcp/chaperone".to_json}))
      expect(worker.args).to include(%(mcp_servers.chaperone.bearer_token_env_var="WORKFLOW_CHAPERONE_TOKEN"))
      expect(JSON.parse(File.read(worker.env_path)).fetch("WORKFLOW_CHAPERONE_TOKEN")).to eq("[set]")
      expect(stdin_write.string).to include("get_chaperone_state")
    end
  end

  describe ".stop_worker" do
    it "signals the worker process group so foreground children stop with their launcher" do
      log_path = File.join(Dir.mktmpdir("worker-stop"), "worker.log")
      File.write(log_path, "")
      worker = instance_double(
        Worker,
        status: "running", pid: 43_210, log_path:, worker_id: "worker-id", run_id: "run-id",
        role: "worker", nickname: "worker", scope: "report.md", reason: "test", command: "claude"
      )
      allow(worker).to receive(:update!)
      allow(Process).to receive(:kill).with(0, 43_210).and_return(1)

      expect(Process).to receive(:kill).with("SIGTERM", -43_210)

      described_class.stop_worker(worker:, reason: "run stopped")
    end
  end
end

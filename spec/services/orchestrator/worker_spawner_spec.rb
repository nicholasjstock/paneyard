require "rails_helper"

RSpec.describe Orchestrator::WorkerSpawner do
  it "extracts diagnosis mode from the planner request used by the spawn path" do
    request = instance_double(
      SpawnRequest, execution_mode: nil,
      text: "Execution mode: diagnosis. Write scope: source_protected."
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
      expect(worker.args).not_to include("--ask-for-approval")
      expect(JSON.parse(File.read(worker.env_path)).fetch("WORKER_LOG_PATH")).to eq(worker.log_path)
      expect(JSON.parse(File.read(worker.env_path)).fetch("XDG_CACHE_HOME")).to start_with(Dir.tmpdir)
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

    # Regression: a linked git worktree's own .git is just a one-line
    # pointer file -- the real metadata (and the shared objects/refs every
    # worktree writes into) lives back in the source checkout's .git/,
    # entirely outside the worktree root_dir a git-managed worker is
    # sandboxed to. Observed live (run-20260727-171200-fffd): the git
    # worker could not create .git/index.lock and failed publication
    # entirely. WorkerSpawner must grant that external .git directory,
    # not just the worktree itself.
    it "grants a git-managed worker write access to the source checkout's external .git directory, not just its own worktree" do
      source_root = Dir.mktmpdir("workflow-worker-spawner-source")
      worktree_root = Dir.mktmpdir("workflow-worker-spawner-worktree")
      workspace = Workspace.create!(name: "git-worker-#{SecureRandom.hex(4)}", root_path: source_root)
      run = workspace.runs.create!(
        run_id: "demo-#{SecureRandom.hex(4)}", task: "Publish the run", target_root: worktree_root,
        source_root:, launcher_variant: "claude", status: "running", launched_by: "operator",
        started_at: Time.current, worktree_name: "demo-a1b2", branch_name: "workflow/demo-a1b2"
      )

      allow(Process).to receive(:spawn).and_return(45_678)
      allow(Process).to receive(:detach)

      worker = described_class.spawn_worker(
        run: run, role: "git", nickname: "git", reason: "Publish.", scope: "publish-demo-a1b2.md",
        prompt: "Commit, rebase, push, and publish.", write_scope: "git_managed", allowed_paths: [ "**/*" ]
      )

      claude_settings_path = worker.mcp_config_path.sub(/\.mcp\.json\z/, ".claude-settings.json")
      settings = JSON.parse(File.read(claude_settings_path))
      external_git_dir = File.join(source_root, ".git")
      expect(settings.dig("sandbox", "filesystem", "allowWrite")).to include(external_git_dir)
      expect(settings["permissions"]["allow"]).to include("Edit(#{external_git_dir}/**)", "Write(#{external_git_dir}/**)")
    ensure
      FileUtils.remove_entry(source_root) if source_root && Dir.exist?(source_root)
      FileUtils.remove_entry(worktree_root) if worktree_root && Dir.exist?(worktree_root)
    end

    it "injects the workspace's recorded project setup into every spawned worker's prompt" do
      workspace_root = Dir.mktmpdir("workflow-worker-spawner-memory")
      workspace = Workspace.create!(name: "memory-#{SecureRandom.hex(4)}", root_path: workspace_root)
      run = workspace.runs.create!(
        run_id: "demo-#{SecureRandom.hex(4)}", task: "Use the recorded dev environment",
        target_root: workspace.root_path, launcher_variant: "claude", status: "running",
        launched_by: "operator", started_at: Time.current
      )
      Orchestrator::ProjectMemory.record!(
        run_id: run.run_id, entry_key: Orchestrator::ProjectInitTrigger::PRIMARY_ENTRY_KEY, kind: "operational_rule",
        content: "Run `bin/dev` from the repository root to start every service together.",
        evidence_ref: "bin/dev", recorded_by: "project_init"
      )

      allow(Process).to receive(:spawn).and_return(34_568)
      allow(Process).to receive(:detach)

      worker = described_class.spawn_worker(
        run: run, role: "worker", nickname: "memory-worker", reason: "Start the app.",
        scope: "task.md", prompt: "Start the app and reproduce the bug."
      )

      expect(File.read(worker.prompt_path)).to include("Run `bin/dev` from the repository root to start every service together.")
    end

    it "includes GitHub App token in worker environment when app is configured" do
      workspace_root = Dir.mktmpdir("workflow-worker-spawner-github-app")
      workspace = Workspace.create!(name: "github-app-#{SecureRandom.hex(4)}", root_path: workspace_root)
      run = workspace.runs.create!(
        run_id: "demo-#{SecureRandom.hex(4)}", task: "GitHub App authenticated task",
        target_root: workspace.root_path, launcher_variant: "claude", status: "running",
        launched_by: "operator", started_at: Time.current
      )

      allow(Process).to receive(:spawn).and_return(56_789)
      allow(Process).to receive(:detach)
      allow(Orchestrator::GitHubAppAuth).to receive(:app_configured?).and_return(true)
      allow(Orchestrator::GitHubAppAuth).to receive(:installation_token_for)
        .with(workspace_root: workspace.root_path).and_return("ghu_test_token_123")

      worker = described_class.spawn_worker(
        run: run, role: "worker", nickname: "github-app-worker", reason: "Test GitHub App auth.",
        scope: "github-task.md", prompt: "Use GitHub App token."
      )

      environment = JSON.parse(File.read(worker.env_path))
      expect(environment).to include("GH_TOKEN" => "[set]")
    end

    it "falls back gracefully when GitHub App is not configured" do
      workspace_root = Dir.mktmpdir("workflow-worker-spawner-no-github-app")
      workspace = Workspace.create!(name: "no-app-#{SecureRandom.hex(4)}", root_path: workspace_root)
      run = workspace.runs.create!(
        run_id: "demo-#{SecureRandom.hex(4)}", task: "Task without GitHub App",
        target_root: workspace.root_path, launcher_variant: "claude", status: "running",
        launched_by: "operator", started_at: Time.current
      )

      allow(Process).to receive(:spawn).and_return(67_890)
      allow(Process).to receive(:detach)
      allow(Orchestrator::GitHubAppAuth).to receive(:app_configured?).and_return(false)

      worker = described_class.spawn_worker(
        run: run, role: "worker", nickname: "no-app-worker", reason: "Task without app config.",
        scope: "task.md", prompt: "Fallback to local auth."
      )

      environment = JSON.parse(File.read(worker.env_path))
      # GH_TOKEN should be empty string (falsy) when not configured
      expect(environment["GH_TOKEN"]).to be_nil
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
      expect(worker.args).not_to include("--tools", "--settings")
      # Chaperone cost/usage went untracked before this: without an
      # explicit --output-format, --print defaults to plain text, not the
      # structured stream WorkerReconcileJob's cost persistence can parse.
      expect(worker.args).to include("--output-format", "stream-json")
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
      expect(worker.model).to eq("gpt-5.6-terra")
      expect(worker.args).to include("--sandbox", "read-only")
      expect(worker.args[worker.args.index("--model") + 1]).to eq("gpt-5.6-terra")
      expect(worker.args).to include(%(mcp_servers.chaperone.url=#{"http://127.0.0.1:3000/mcp/chaperone".to_json}))
      expect(worker.args).to include(%(mcp_servers.chaperone.bearer_token_env_var="WORKFLOW_CHAPERONE_TOKEN"))
      expect(JSON.parse(File.read(worker.env_path)).fetch("WORKFLOW_CHAPERONE_TOKEN")).to eq("[set]")
      expect(stdin_write.string).to include("get_chaperone_state")
    end

    it "resumes the run's most recent same-role session, even across different steps" do
      workspace_root = Dir.mktmpdir("workflow-worker-spawner-resume")
      workspace = Workspace.create!(name: "resume-#{SecureRandom.hex(4)}", root_path: workspace_root)
      run = workspace.runs.create!(
        run_id: "demo-#{SecureRandom.hex(4)}", task: "Implement the feature",
        target_root: workspace.root_path, launcher_variant: "claude", status: "running",
        launched_by: "operator", started_at: Time.current
      )

      spawn_calls = []
      allow(Process).to receive(:spawn) do |*args, **kwargs|
        spawn_calls << kwargs
        spawn_calls.length == 1 ? 11_111 : 22_222
      end
      allow(Process).to receive(:detach)

      first = described_class.spawn_worker(
        run: run, role: "worker", nickname: "worker", reason: "Phase 1.", scope: "phase-1.md",
        prompt: "Implement phase 1.", lineage_key: "phase-1-lineage"
      )
      expect(first.cli_session_id).to be_present
      expect(first.lineage_key).to eq("phase-1-lineage")

      second = described_class.spawn_worker(
        run: run, role: "worker", nickname: "worker-1", reason: "Phase 2.", scope: "phase-2.md",
        prompt: "Implement phase 2.", lineage_key: "phase-2-lineage"
      )

      expect(second.args).to include("--resume", first.cli_session_id)
      expect(second.args).not_to include("--session-id")
      expect(second.cli_session_id).to eq(first.cli_session_id)
      # The actual bug this regression-tests: Claude Code's own session
      # storage is scoped to cwd, so a --resume must run from the exact
      # same directory the session was originally created in, not a fresh
      # one per spawn -- otherwise the CLI reports "No conversation found"
      # even though the session id is correct.
      expect(spawn_calls[1][:chdir]).to eq(spawn_calls[0][:chdir])
    end

    it "prior_worker_for_resume skips a same-role session that crashed with zero turns, falling back further in history" do
      workspace_root = Dir.mktmpdir("workflow-worker-spawner-dead-session")
      workspace = Workspace.create!(name: "dead-session-#{SecureRandom.hex(4)}", root_path: workspace_root)
      run = workspace.runs.create!(
        run_id: "demo-#{SecureRandom.hex(4)}", task: "Implement the feature",
        target_root: workspace.root_path, launcher_variant: "claude", status: "running",
        launched_by: "operator", started_at: Time.current
      )
      good_session = SecureRandom.uuid
      dead_session = SecureRandom.uuid
      create_stopped_worker(
        run, "worker", cli_session_id: good_session, agent_turn_count: 34,
        handoff_completed_at: 2.minutes.ago, created_at: 2.minutes.ago
      )
      # Simulates claude's own "No conversation found with session ID" crash --
      # the resume target's own working directory mismatch (the actual bug
      # fixed alongside this) means the CLI never re-establishes the
      # session, so num_turns comes back 0. Without this filter,
      # prior_worker_for_resume would keep selecting this dead session
      # forever, since every subsequent resume attempt also inherits it.
      create_stopped_worker(run, "worker", cli_session_id: dead_session, agent_turn_count: 0, created_at: 1.minute.ago)

      selected = described_class.prior_worker_for_resume(run_id: run.run_id, role: "worker", driver: "claude")

      expect(selected.cli_session_id).to eq(good_session)
    end

    it "prior_worker_for_resume skips a stopped worker with no recorded turns, even when it minted the session" do
      workspace_root = Dir.mktmpdir("workflow-worker-spawner-unreconciled-session")
      workspace = Workspace.create!(name: "unreconciled-#{SecureRandom.hex(4)}", root_path: workspace_root)
      run = workspace.runs.create!(
        run_id: "demo-#{SecureRandom.hex(4)}", task: "Implement the feature",
        target_root: workspace.root_path, launcher_variant: "claude", status: "running",
        launched_by: "operator", started_at: Time.current
      )
      # StopRunJob (a manual "Kill run") sets status directly and never runs
      # WorkerReconcileJob's usage-parsing, so a worker killed this way sits
      # at agent_turn_count=nil forever -- indistinguishable from "still
      # running" under a NULL-tolerant filter, but this one is stopped and
      # never proved its session established. Confirmed against a real run
      # where exactly this worker kept getting selected as a resume source.
      nickname = "worker-#{SecureRandom.hex(4)}"
      run.workers.create!(
        worker_id: SecureRandom.uuid, role: "worker", nickname:, reason: "test", scope: "artifact.md",
        status: "stopped", pid: 12_345, command: "claude", args: [],
        prompt_path: Rails.root.join("tmp/#{nickname}.prompt").to_s,
        log_path: Rails.root.join("tmp/#{nickname}.log").to_s,
        last_message_path: Rails.root.join("tmp/#{nickname}.last").to_s,
        env_path: Rails.root.join("tmp/#{nickname}.env").to_s,
        cli_session_id: SecureRandom.uuid, agent_turn_count: nil
      )

      selected = described_class.prior_worker_for_resume(run_id: run.run_id, role: "worker", driver: "claude")

      expect(selected).to be_nil
    end

    it "prior_worker_for_resume still accepts a currently running worker whose usage isn't reconciled yet" do
      workspace_root = Dir.mktmpdir("workflow-worker-spawner-running-session")
      workspace = Workspace.create!(name: "running-#{SecureRandom.hex(4)}", root_path: workspace_root)
      run = workspace.runs.create!(
        run_id: "demo-#{SecureRandom.hex(4)}", task: "Implement the feature",
        target_root: workspace.root_path, launcher_variant: "claude", status: "running",
        launched_by: "operator", started_at: Time.current
      )
      nickname = "worker-#{SecureRandom.hex(4)}"
      running_session = SecureRandom.uuid
      run.workers.create!(
        worker_id: SecureRandom.uuid, role: "worker", nickname:, reason: "test", scope: "artifact.md",
        status: "running", pid: 12_345, command: "claude", args: [],
        prompt_path: Rails.root.join("tmp/#{nickname}.prompt").to_s,
        log_path: Rails.root.join("tmp/#{nickname}.log").to_s,
        last_message_path: Rails.root.join("tmp/#{nickname}.last").to_s,
        env_path: Rails.root.join("tmp/#{nickname}.env").to_s,
        cli_session_id: running_session, agent_turn_count: nil
      )

      selected = described_class.prior_worker_for_resume(run_id: run.run_id, role: "worker", driver: "claude")

      expect(selected.cli_session_id).to eq(running_session)
    end

    def create_stopped_worker(run, role, cli_session_id:, agent_turn_count:, handoff_completed_at: nil, created_at:)
      nickname = "worker-#{SecureRandom.hex(4)}"
      run.workers.create!(
        worker_id: SecureRandom.uuid, role:, nickname:, reason: "test", scope: "artifact.md",
        status: "stopped", pid: 12_345, command: "claude", args: [],
        prompt_path: Rails.root.join("tmp/#{nickname}.prompt").to_s,
        log_path: Rails.root.join("tmp/#{nickname}.log").to_s,
        last_message_path: Rails.root.join("tmp/#{nickname}.last").to_s,
        env_path: Rails.root.join("tmp/#{nickname}.env").to_s,
        cli_session_id:, agent_turn_count:, handoff_completed_at:, created_at:
      )
    end

    it "never resumes across a role change even when the lineage_key is identical" do
      workspace_root = Dir.mktmpdir("workflow-worker-spawner-role-boundary")
      workspace = Workspace.create!(name: "role-boundary-#{SecureRandom.hex(4)}", root_path: workspace_root)
      run = workspace.runs.create!(
        run_id: "demo-#{SecureRandom.hex(4)}", task: "Implement then verify",
        target_root: workspace.root_path, launcher_variant: "claude", status: "running",
        launched_by: "operator", started_at: Time.current
      )

      allow(Process).to receive(:spawn).and_return(11_112, 22_223)
      allow(Process).to receive(:detach)

      implementer = described_class.spawn_worker(
        run: run, role: "worker", nickname: "worker", reason: "Implement.", scope: "impl.md",
        prompt: "Implement it.", lineage_key: "shared-lineage"
      )

      verifier = described_class.spawn_worker(
        run: run, role: "verifier", nickname: "verifier", reason: "Verify.", scope: "impl.md",
        prompt: "Verify it independently.", lineage_key: "shared-lineage"
      )

      expect(verifier.args).not_to include("--resume")
      expect(verifier.args).not_to include(implementer.cli_session_id)
      expect(verifier.cli_session_id).not_to eq(implementer.cli_session_id)
    end

    it "chaperone spawns never resume, regardless of lineage_key" do
      workspace_root = Dir.mktmpdir("workflow-worker-spawner-chaperone-resume")
      workspace = Workspace.create!(name: "chaperone-resume-#{SecureRandom.hex(4)}", root_path: workspace_root)
      run = workspace.runs.create!(
        run_id: "demo-#{SecureRandom.hex(4)}", task: "Implement then chaperone-review",
        target_root: workspace.root_path, launcher_variant: "claude", status: "running",
        launched_by: "operator", started_at: Time.current
      )

      allow(Process).to receive(:spawn).and_return(11_113, 22_224)
      allow(Process).to receive(:detach)

      described_class.spawn_worker(
        run: run, role: "worker", nickname: "worker", reason: "Implement.", scope: "impl.md",
        prompt: "Implement it.", lineage_key: "shared-lineage"
      )

      chaperone = described_class.spawn_worker(
        run: run, role: "chaperone", nickname: "chaperone", reason: "Review.", scope: "impl.md",
        prompt: "Review it.", model_tier: "strong", lineage_key: "shared-lineage",
        mcp_override: { url: "http://127.0.0.1:3000/mcp/chaperone", token: "tok", allowed_tools: [] }
      )

      expect(chaperone.args).to include("--no-session-persistence")
      expect(chaperone.args).not_to include("--resume")
      expect(chaperone.cli_session_id).to be_nil
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

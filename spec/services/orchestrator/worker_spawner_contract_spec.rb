require "rails_helper"

RSpec.describe Orchestrator::WorkerSpawner do
  it "Claude workers request incremental stream output" do
    root = Dir.mktmpdir("worker-policy")
    policy = Orchestrator::WorkerExecutionPolicy.new(
      root_dir: root, mode: "diagnosis", write_scope: "source_protected", allowed_paths: []
    )
    args = Orchestrator::WorkerSpawner.send(
      :claude_args, "Do the work.", role: "worker", mcp_config_path: "/tmp/mcp.json",
      settings_path: "/tmp/settings.json", target_root: root, policy:
    )

    assert_includes args, "stream-json"
    assert_includes args, "--include-partial-messages"
    assert_includes args, "Bash,Read,Grep,Glob,ToolSearch"
    assert_equal "bypassPermissions", args[args.index("--permission-mode") + 1]
    refute_includes args, "dontAsk"
    assert_equal "haiku", args[args.index("--model") + 1]
    assert_equal "Do the work.", args.last
  end

  it "omits --effort when none is given, and passes it through when it is" do
    root = Dir.mktmpdir("worker-policy")
    policy = Orchestrator::WorkerExecutionPolicy.new(
      root_dir: root, mode: "diagnosis", write_scope: "source_protected", allowed_paths: []
    )

    plain_args = Orchestrator::WorkerSpawner.send(
      :claude_args, "Do the work.", role: "worker", mcp_config_path: "/tmp/mcp.json",
      settings_path: "/tmp/settings.json", target_root: root, policy:
    )
    refute_includes plain_args, "--effort"

    effort_args = Orchestrator::WorkerSpawner.send(
      :claude_args, "Do the work.", role: "worker", mcp_config_path: "/tmp/mcp.json",
      settings_path: "/tmp/settings.json", target_root: root, policy:, effort: "high"
    )
    assert_equal "high", effort_args[effort_args.index("--effort") + 1]
  end

  it "keeps Bash for writing workers and adds only policy-backed edit tools" do
    root = Dir.mktmpdir("worker-policy")
    policy = Orchestrator::WorkerExecutionPolicy.new(
      root_dir: root, mode: "implementation", write_scope: "scoped_changes",
      allowed_paths: [ "app/services/example.rb" ]
    )

    assert_equal "Bash,Read,Grep,Glob,ToolSearch,Edit,Write", policy.claude_tools
    assert_equal [ File.join(root, "app/services/example.rb") ],
      policy.claude_settings.dig("sandbox", "filesystem", "allowWrite")
    assert_includes policy.claude_settings.dig("permissions", "allow"),
      "Edit(/#{File.join(root, 'app/services/example.rb').delete_prefix('/')})"
  end

  it "runs normal Codex workers without the host sandbox" do
    root = Dir.mktmpdir("worker-policy")
    policy = Orchestrator::WorkerExecutionPolicy.new(
      root_dir: root, mode: "infrastructure", write_scope: "scoped_changes",
      allowed_paths: [ "config/queue.yml" ], profile_name: "worker-123"
    )
    args = Orchestrator::WorkerSpawner.send(
      :codex_args, root_dir: root, last_message_path: "/tmp/last.txt", policy:
    )

    refute_includes args, "--ask-for-approval"
    assert_includes args, "--dangerously-bypass-approvals-and-sandbox"
  end

  it "codex has no dedicated effort flag -- passes it as a -c model_reasoning_effort override instead" do
    root = Dir.mktmpdir("worker-policy")
    policy = Orchestrator::WorkerExecutionPolicy.new(
      root_dir: root, mode: "infrastructure", write_scope: "scoped_changes",
      allowed_paths: [ "config/queue.yml" ], profile_name: "worker-123"
    )

    plain_args = Orchestrator::WorkerSpawner.send(
      :codex_args, root_dir: root, last_message_path: "/tmp/last.txt", policy:
    )
    refute plain_args.any? { |arg| arg.include?("model_reasoning_effort") }

    effort_args = Orchestrator::WorkerSpawner.send(
      :codex_args, root_dir: root, last_message_path: "/tmp/last.txt", policy:, effort: "high"
    )
    assert_includes effort_args, %(model_reasoning_effort="high")
  end

  it "reads a role's declared effort from its persona frontmatter, falling back to nil if it has none" do
    assert_equal "high", Orchestrator::WorkerSpawner.send(:persona_declared_effort, "chaperone")
    assert_equal "medium", Orchestrator::WorkerSpawner.send(:persona_declared_effort, "worker")
    # The planner has no agent_personas/planner.md at all (it's a Rails job,
    # not a spawned worker) -- persona_declared_effort must still return nil
    # rather than raise.
    assert_nil Orchestrator::WorkerSpawner.send(:persona_declared_effort, "planner")
  end

  it "strips the persona frontmatter out of the prompt actually sent to the model" do
    prompt = Orchestrator::WorkerSpawner.send(
      :build_prompt_with_persona, driver: "claude", role: "chaperone", prompt: "task"
    )
    refute_includes prompt, "effort: high"
    refute_includes prompt, "---"
    assert_includes prompt, "bounded review process"
  end

  it "uses the small tier by default and only uses the strong tier after promotion" do
    assert_equal "haiku", Orchestrator::WorkerSpawner.send(:claude_model_for, "worker", mode: "diagnosis")
    assert_equal "sonnet", Orchestrator::WorkerSpawner.send(:claude_model_for, "worker", mode: "diagnosis", model_tier: "strong")
    assert_equal "haiku", Orchestrator::WorkerSpawner.send(:claude_model_for, "worker")
    assert_equal "haiku", Orchestrator::WorkerSpawner.send(:claude_model_for, "infrastructure")
    assert_equal "gpt-5.6-luna", Orchestrator::WorkerSpawner.send(:codex_model_for)
    assert_equal "gpt-5.6-terra", Orchestrator::WorkerSpawner.send(:codex_model_for, model_tier: "strong")
  end

  it "passes the promoted Codex model to both ordinary and chaperone workers" do
    root = Dir.mktmpdir("worker-policy")
    policy = Orchestrator::WorkerExecutionPolicy.new(
      root_dir: root, mode: "diagnosis", write_scope: "source_protected", allowed_paths: []
    )

    ordinary_args = Orchestrator::WorkerSpawner.send(
      :codex_args, root_dir: root, last_message_path: "/tmp/last.txt", policy:, model_tier: "strong"
    )
    chaperone_args = Orchestrator::WorkerSpawner.send(
      :codex_args, root_dir: root, last_message_path: "/tmp/last.txt", policy:, model_tier: "strong",
      mcp_override: { url: "http://127.0.0.1:3000/mcp/chaperone", server_name: "chaperone" }
    )

    assert_equal "gpt-5.6-terra", ordinary_args[ordinary_args.index("--model") + 1]
    assert_equal "gpt-5.6-terra", chaperone_args[chaperone_args.index("--model") + 1]
  end

  # opencode_args must always return [args_array, env_hash], same shape for
  # both the ordinary and mcp_override branches -- the caller destructures
  # it as `oc_args, oc_env = opencode_args(...)`. A prior version's
  # mcp_override branch returned a bare args array, which Ruby's multiple
  # assignment silently spread across oc_args/oc_env (oc_env became a
  # string, e.g. "--format"), blowing up downstream with "no implicit
  # conversion of String into Hash" the moment a real reply_received/
  # chaperone opencode worker tried to spawn -- and since the override MCP
  # server was never wired into any env var either, the worker would have
  # had no way to reach it even if the crash hadn't happened first.
  it "opencode mcp_override workers get a proper [args, env] tuple wiring the override MCP server" do
    root = Dir.mktmpdir("worker-policy")
    policy = Orchestrator::WorkerExecutionPolicy.new(
      root_dir: root, mode: "diagnosis", write_scope: "source_protected", allowed_paths: []
    )

    result = Orchestrator::WorkerSpawner.send(
      :opencode_args, "Classify the reply.", root_dir: root, last_message_path: "/tmp/last.txt", policy:,
      mcp_override: { url: "http://127.0.0.1:3000/mcp/reply_received", server_name: "reply_received", token: "secret-token" }
    )

    assert_equal 2, result.length
    args, env = result
    assert_instance_of Array, args
    assert_includes args, "run"
    assert_instance_of Hash, env
    config = JSON.parse(env.fetch("OPENCODE_CONFIG_CONTENT"))
    assert_equal "http://127.0.0.1:3000/mcp/reply_received", config.dig("mcp", "reply_received", "url")
    assert_equal "Bearer secret-token", config.dig("mcp", "reply_received", "headers", "Authorization")
  end

  # Orchestrator::WorkerMcpEndpoint#call rejects any request without a valid
  # "Bearer <capability_token>" Authorization header with a bare 401 --
  # confirmed live: an ordinary opencode worker whose config omitted this
  # header saw zero tools from the "workflow" MCP server (write_workflow_artifact,
  # worker_turn) at all, with no error surfaced to the model. It could still
  # do real file/shell work, but could never call worker_turn to report back,
  # which repeatedly tripped Rails' dead-end recovery into re-planning.
  it "ordinary opencode workers authenticate the workflow MCP connection with their capability token" do
    root = Dir.mktmpdir("worker-policy")
    policy = Orchestrator::WorkerExecutionPolicy.new(
      root_dir: root, mode: "diagnosis", write_scope: "source_protected", allowed_paths: []
    )

    args, env = Orchestrator::WorkerSpawner.send(
      :opencode_args, "Begin.", root_dir: root, last_message_path: "/tmp/last.txt", policy:,
      capability_token: "worker-capability-token"
    )

    assert_instance_of Array, args
    config = JSON.parse(env.fetch("OPENCODE_CONFIG_CONTENT"))
    assert_equal "Bearer worker-capability-token", config.dig("mcp", "workflow", "headers", "Authorization")
  end

  # Neither driver is pre-assigned a session id anymore -- claude mints its
  # own on a fresh spawn, same as codex always has, so --session-id is
  # dropped entirely rather than passed a value chosen up front.
  it "claude workers on a fresh spawn omit --session-id, letting claude mint its own" do
    root = Dir.mktmpdir("worker-policy")
    policy = Orchestrator::WorkerExecutionPolicy.new(
      root_dir: root, mode: "diagnosis", write_scope: "source_protected", allowed_paths: []
    )
    args = Orchestrator::WorkerSpawner.send(
      :claude_args, "Do the work.", role: "worker", mcp_config_path: "/tmp/mcp.json",
      settings_path: "/tmp/settings.json", target_root: root, policy:
    )

    refute_includes args, "--session-id"
    refute_includes args, "--resume"
    refute_includes args, "--no-session-persistence"
  end

  it "claude workers resume a prior session instead of minting a fresh one" do
    root = Dir.mktmpdir("worker-policy")
    policy = Orchestrator::WorkerExecutionPolicy.new(
      root_dir: root, mode: "diagnosis", write_scope: "source_protected", allowed_paths: []
    )
    args = Orchestrator::WorkerSpawner.send(
      :claude_args, "Do the work.", role: "worker", mcp_config_path: "/tmp/mcp.json",
      settings_path: "/tmp/settings.json", target_root: root, policy:,
      resume_session_id: "prior-id"
    )

    assert_equal "prior-id", args[args.index("--resume") + 1]
    refute_includes args, "--session-id"
  end

  it "chaperone claude spawns never resume, even if a resume_session_id is passed" do
    root = Dir.mktmpdir("worker-policy")
    policy = Orchestrator::WorkerExecutionPolicy.new(
      root_dir: root, mode: "diagnosis", write_scope: "source_protected", allowed_paths: []
    )
    args = Orchestrator::WorkerSpawner.send(
      :claude_args, "Review this.", role: "chaperone", mcp_config_path: "/tmp/mcp.json",
      settings_path: "/tmp/settings.json", target_root: root, policy:,
      resume_session_id: "prior-id", mcp_override: { url: "http://127.0.0.1:3000/mcp/chaperone", server_name: "chaperone", allowed_tools: [] }
    )

    assert_includes args, "--no-session-persistence"
    refute_includes args, "--resume"
    refute_includes args, "prior-id"
  end

  it "codex workers add --json (needed to capture session_meta) and no resume subcommand on a fresh spawn" do
    root = Dir.mktmpdir("worker-policy")
    policy = Orchestrator::WorkerExecutionPolicy.new(
      root_dir: root, mode: "diagnosis", write_scope: "source_protected", allowed_paths: []
    )
    args = Orchestrator::WorkerSpawner.send(
      :codex_args, root_dir: root, last_message_path: "/tmp/last.txt", policy:
    )

    assert_includes args, "--json"
    refute_includes args, "resume"
    assert_equal root, args[args.index("-C") + 1]
  end

  it "codex workers resume via the exec resume subcommand, without -C (unsupported by codex exec resume)" do
    root = Dir.mktmpdir("worker-policy")
    policy = Orchestrator::WorkerExecutionPolicy.new(
      root_dir: root, mode: "diagnosis", write_scope: "source_protected", allowed_paths: []
    )
    args = Orchestrator::WorkerSpawner.send(
      :codex_args, root_dir: root, last_message_path: "/tmp/last.txt", policy:, resume_session_id: "prior-id"
    )

    assert_equal [ "exec", "resume", "prior-id" ], args.first(3)
    assert_includes args, "--json"
    refute_includes args, "-C"
  end

  it "chaperone codex spawns never resume, even if a resume_session_id is passed" do
    root = Dir.mktmpdir("worker-policy")
    policy = Orchestrator::WorkerExecutionPolicy.new(
      root_dir: root, mode: "diagnosis", write_scope: "source_protected", allowed_paths: []
    )
    args = Orchestrator::WorkerSpawner.send(
      :codex_args, root_dir: root, last_message_path: "/tmp/last.txt", policy:,
      resume_session_id: "prior-id", mcp_override: { url: "http://127.0.0.1:3000/mcp/chaperone", server_name: "chaperone" }
    )

    assert_includes args, "--ephemeral"
    refute_includes args, "resume"
    refute_includes args, "prior-id"
  end

  describe ".prior_worker_for_resume" do
    it "returns the most recent same-role session in the run, never another role or run" do
      run = create_run
      other_run = create_run
      run.workers.create!(worker_attrs(
        role: "worker", lineage_key: "lineage-a", cli_session_id: "older-id", handoff_completed_at: Time.current
      ))
      newest = run.workers.create!(worker_attrs(
        role: "worker", lineage_key: "lineage-b", cli_session_id: "newest-id", handoff_completed_at: Time.current
      ))
      run.workers.create!(worker_attrs(role: "verifier", lineage_key: "lineage-a", cli_session_id: "wrong-role"))
      other_run.workers.create!(worker_attrs(role: "worker", lineage_key: "lineage-a", cli_session_id: "wrong-run"))

      found = Orchestrator::WorkerSpawner.send(
        :prior_worker_for_resume, run_id: run.run_id, role: "worker", driver: "claude"
      )

      assert_equal newest.id, found.id
    end

    it "ignores a stale same-role session that never completed its handoff" do
      run = create_run
      completed = run.workers.create!(worker_attrs(
        role: "worker", lineage_key: "lineage-a", cli_session_id: "completed-id",
        handoff_completed_at: Time.current
      ))
      run.workers.create!(worker_attrs(
        role: "worker", lineage_key: "lineage-b", cli_session_id: "stale-id", handoff_completed_at: nil
      ))

      found = Orchestrator::WorkerSpawner.send(
        :prior_worker_for_resume, run_id: run.run_id, role: "worker"
      )

      assert_equal completed.id, found.id
    end

    it "returns no resume candidate when every same-role session is stale" do
      run = create_run
      run.workers.create!(worker_attrs(
        role: "worker", lineage_key: "lineage-a", cli_session_id: "stale-id", handoff_completed_at: nil
      ))

      found = Orchestrator::WorkerSpawner.send(
        :prior_worker_for_resume, run_id: run.run_id, role: "worker"
      )

      assert_nil found
    end

    it "ignores a prior worker with no captured cli_session_id yet" do
      run = create_run
      run.workers.create!(worker_attrs(role: "worker", lineage_key: "lineage-a", cli_session_id: nil))

      found = Orchestrator::WorkerSpawner.send(
        :prior_worker_for_resume, run_id: run.run_id, role: "worker", driver: "claude"
      )

      assert_nil found
    end

    it "never resumes a Claude session from a Codex worker, even for the same run and role" do
      run = create_run
      run.workers.create!(worker_attrs(
        role: "worker", lineage_key: "lineage-a", cli_session_id: "claude-session", command: "claude"
      ))
      found = Orchestrator::WorkerSpawner.send(
        :prior_worker_for_resume, run_id: run.run_id, role: "worker", driver: "codex"
      )

      assert_nil found
    end
  end

  it "infrastructure workers receive the generic worker contract and skill" do
    assert_equal Rails.root.join("agent_personas", "infrastructure_skill.md"),
      Orchestrator::WorkerSpawner.send(:infrastructure_skill_path)

    prompt = Orchestrator::WorkerSpawner.send(
      :build_prompt_with_persona, driver: "claude", role: "infrastructure", prompt: "Diagnose the outage."
    )
    codex_prompt = Orchestrator::WorkerSpawner.send(
      :build_prompt_with_persona, driver: "codex", role: "infrastructure", prompt: "Diagnose the outage."
    )

    assert_includes prompt, "call `worker_turn`"
    assert_includes prompt, "evidence-driven reliability investigation"
    assert_includes prompt, "Current task:\nDiagnose the outage."
    assert_includes codex_prompt, "call `worker_turn`"
    assert_includes codex_prompt, "evidence-driven reliability investigation"
  end

  def create_run
    root = Dir.mktmpdir("worker-spawner-contract")
    workspace = Workspace.create!(name: "worker-spawner-contract-#{SecureRandom.hex(4)}", root_path: root)
    workspace.runs.create!(
      run_id: "worker-spawner-contract-#{SecureRandom.hex(4)}", task: "Exercise resume lookup",
      target_root: root, launcher_variant: "claude", status: "running"
    )
  end

  def worker_attrs(role:, lineage_key:, cli_session_id:, agent_turn_count: 10, command: "claude", handoff_completed_at: nil)
    id = SecureRandom.uuid
    {
      worker_id: id, role:, nickname: "worker-#{id}", reason: "test", scope: "test.md", status: "stopped",
      pid: 1, prompt_path: "/tmp/#{id}.prompt", log_path: "/tmp/#{id}.log",
      last_message_path: "/tmp/#{id}.last", env_path: "/tmp/#{id}.env", command:,
      lineage_key:, cli_session_id:, agent_turn_count: cli_session_id.nil? ? nil : agent_turn_count,
      handoff_completed_at:
    }
  end
end

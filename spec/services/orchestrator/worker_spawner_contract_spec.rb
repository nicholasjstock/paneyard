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
    refute_includes args, "bypassPermissions"
    assert_equal "haiku", args[args.index("--model") + 1]
    assert_equal "Do the work.", args.last
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

  it "gives Codex exact write grants without bypassing its sandbox" do
    root = Dir.mktmpdir("worker-policy")
    policy = Orchestrator::WorkerExecutionPolicy.new(
      root_dir: root, mode: "infrastructure", write_scope: "scoped_changes",
      allowed_paths: [ "config/queue.yml" ], profile_name: "worker-123"
    )
    args = Orchestrator::WorkerSpawner.send(
      :codex_args, root_dir: root, last_message_path: "/tmp/last.txt", policy:
    )

    refute_includes args, "--ask-for-approval"
    assert_includes args, 'default_permissions="worker-123"'
    assert args.any? { |arg| arg.include?('"config/queue.yml"="write"') }
    refute_includes args, "--dangerously-bypass-approvals-and-sandbox"
  end

  it "fails closed when legacy Codex sandbox configuration would disable the exact profile" do
    root = Dir.mktmpdir("worker-policy")
    FileUtils.mkdir_p(File.join(root, ".codex"))
    File.write(File.join(root, ".codex", "config.toml"), "sandbox_mode = \"workspace-write\"\n")

    expect do
      Orchestrator::WorkerSpawner.send(:validate_codex_permission_profile_compatibility!, root)
    end.to raise_error(ArgumentError, /cannot coexist with legacy sandbox_mode/)
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
      mcp_override: { url: "http://127.0.0.1:3000/mcp/chaperone" }
    )

    assert_equal "gpt-5.6-terra", ordinary_args[ordinary_args.index("--model") + 1]
    assert_equal "gpt-5.6-terra", chaperone_args[chaperone_args.index("--model") + 1]
  end

  it "infrastructure workers receive the generic worker contract and skill" do
    assert_equal Rails.root.join(".claude", "skills", "infrastructure", "SKILL.md"),
      Orchestrator::WorkerSpawner.send(:infrastructure_skill_path, "claude")
    assert_equal Rails.root.join(".codex", "skills", "infrastructure", "SKILL.md"),
      Orchestrator::WorkerSpawner.send(:infrastructure_skill_path, "codex")

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
end

require "rails_helper"
require "tmpdir"

RSpec.describe Orchestrator::WorkspaceChatRunner do
  it "runs a sandboxed Codex turn and captures the response" do
    Dir.mktmpdir do |root|
      chat = create_chat(root:, launcher_variant: "codex")
      captured = nil
      runner = lambda do |env, *args, chdir:|
        captured = { env:, args:, chdir: }
        output = <<~JSONL
          {"type":"item.completed","item":{"type":"agent_message","text":"The run is healthy."}}
          {"type":"turn.completed","usage":{"input_tokens":20,"output_tokens":6}}
        JSONL
        [ output, "", fake_status(true) ]
      end

      result = Orchestrator::WorkspaceChatRunner.call(chat:, message: "What is happening?", command_runner: runner)

      assert_equal "The run is healthy.", result[:response]
      assert_nil result[:session_id]
      assert_equal root, captured[:chdir]
      assert_includes captured[:args], "workspace-write"
      assert_includes captured[:args], Orchestrator::WorkerSpawner::CODEX_WORKER_MODEL
      assert_includes captured[:args].join(" "), "/mcp/workspace-chat"
      refute_includes captured[:args].join(" "), "mcp_servers.workflow"
      refute_includes captured[:args], "resume"
      assert captured[:env]["WORKSPACE_CHAT_TOKEN"].present?
    end
  end

  it "runs a Claude turn with broad worktree tool access alongside the curated MCP server" do
    Dir.mktmpdir do |root|
      chat = create_chat(root:, launcher_variant: "claude")
      captured = nil
      mcp_config = nil
      envelope = { "result" => "The run is healthy.", "usage" => { "input_tokens" => 12, "output_tokens" => 4 }, "total_cost_usd" => 0.001 }
      runner = lambda do |env, *args, chdir:|
        captured = { env:, args:, chdir: }
        mcp_config_path = args[args.index("--mcp-config") + 1]
        mcp_config = JSON.parse(File.read(mcp_config_path))
        [ JSON.generate(envelope), "", fake_status(true) ]
      end

      result = Orchestrator::WorkspaceChatRunner.call(chat:, message: "What is happening?", command_runner: runner)

      assert_equal "The run is healthy.", result[:response]
      assert_equal 12, result.dig(:usage, :input_tokens)
      assert_equal root, captured[:chdir]
      assert_equal "sonnet", captured[:args][captured[:args].index("--model") + 1]
      tools = captured[:args][captured[:args].index("--tools") + 1]
      assert_includes tools, "Bash"
      assert_includes tools, "Edit"
      assert_includes tools, "Write"
      refute_includes captured[:args], "--allowedTools"
      assert_includes mcp_config.dig("mcpServers", "workspace_chat", "url"), "/mcp/workspace-chat"
    end
  end

  it "folds recent completed messages into the prompt instead of relying on CLI session memory" do
    Dir.mktmpdir do |root|
      chat = create_chat(root:, launcher_variant: "claude")
      chat.messages.create!(role: "user", content: "What is the current run doing?", status: "completed")
      chat.messages.create!(role: "assistant", content: "It is verifying the fix.", status: "completed")
      chat.messages.create!(role: "user", content: "Still in flight?", status: "processing")

      prompt = Orchestrator::WorkspaceChatRunner.build_prompt(chat:, message: "Still in flight?")

      assert_includes prompt, "Operator: What is the current run doing?"
      assert_includes prompt, "Assistant: It is verifying the fix."
      assert_equal 1, prompt.scan("Still in flight?").length
    end
  end

  private

  def create_chat(root:, launcher_variant: "claude")
    workspace = Workspace.create!(name: "chat-#{SecureRandom.hex(4)}", root_path: root)
    workspace.workspace_chats.create!(launcher_variant:)
  end

  def fake_status(success)
    Struct.new(:success?, :exitstatus).new(success, success ? 0 : 1)
  end
end

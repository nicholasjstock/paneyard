require "test_helper"
require "tmpdir"

class WorkspaceChatRunnerTest < ActiveSupport::TestCase
  test "starts a sandboxed workspace session and captures its id" do
    Dir.mktmpdir do |root|
      chat = create_chat(root:)
      captured = nil
      runner = lambda do |env, *args, chdir:|
        captured = { env:, args:, chdir: }
        output = <<~JSONL
          {"type":"thread.started","thread_id":"thread-123"}
          {"type":"item.completed","item":{"type":"agent_message","text":"The run is healthy."}}
          {"type":"turn.completed","usage":{"input_tokens":20,"output_tokens":6}}
        JSONL
        [ output, "", fake_status(true) ]
      end

      result = Orchestrator::WorkspaceChatRunner.call(chat:, message: "What is happening?", command_runner: runner)

      assert_equal "thread-123", result[:session_id]
      assert_equal "The run is healthy.", result[:response]
      assert_equal root, captured[:chdir]
      assert_includes captured[:args], "workspace-write"
      assert_includes captured[:args], Orchestrator::WorkerSpawner::CODEX_WORKER_MODEL
      assert_includes captured[:args].join(" "), "/mcp/workspace-chat"
      refute_includes captured[:args].join(" "), "mcp_servers.workflow"
      assert captured[:env]["WORKSPACE_CHAT_TOKEN"].present?
    end
  end

  test "resumes the workspace's existing session" do
    Dir.mktmpdir do |root|
      chat = create_chat(root:)
      chat.update!(session_id: "thread-existing")
      captured_args = nil
      runner = lambda do |_env, *args, chdir:|
        captured_args = args
        [ %({"type":"item.completed","item":{"type":"agent_message","text":"Continued."}}\n), "", fake_status(true) ]
      end

      result = Orchestrator::WorkspaceChatRunner.call(chat:, message: "Continue", command_runner: runner)

      assert_equal "Continued.", result[:response]
      assert_equal %w[codex exec resume], captured_args.first(3)
      assert_includes captured_args, "thread-existing"
    end
  end

  private

  def create_chat(root:)
    workspace = Workspace.create!(name: "chat-#{SecureRandom.hex(4)}", root_path: root)
    workspace.workspace_chats.create!
  end

  def fake_status(success)
    Struct.new(:success?, :exitstatus).new(success, success ? 0 : 1)
  end
end

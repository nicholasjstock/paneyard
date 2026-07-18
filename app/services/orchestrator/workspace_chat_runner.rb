require "open3"

module Orchestrator
  module WorkspaceChatRunner
    class Error < StandardError; end

    module_function

    MODEL = WorkerSpawner::CODEX_WORKER_MODEL

    def call(chat:, message:, command_runner: Open3.method(:capture3))
      token = WorkspaceChatCapability.issue(chat)
      prompt = build_prompt(chat:, message:)
      env = WorkerSpawner.build_worker_env.merge("WORKSPACE_CHAT_TOKEN" => token)
      stdout, stderr, status = command_runner.call(env, *args(chat:, prompt:), chdir: chat.workspace.root_path)
      raise Error, "Workspace chat exited #{status.exitstatus}: #{stderr.presence || stdout}" unless status.success?

      parse(stdout, require_session_id: chat.session_id.blank?)
    end

    def args(chat:, prompt:)
      common = [
        "--model", MODEL, "--json", "--ignore-user-config",
        "-c", 'sandbox_mode="workspace-write"',
        "-c", "mcp_servers.workspace_chat.url=\"#{workspace_chat_mcp_url}\"",
        "-c", 'mcp_servers.workspace_chat.bearer_token_env_var="WORKSPACE_CHAT_TOKEN"'
      ]
      if chat.session_id.present?
        [ "codex", "exec", "resume", *common, chat.session_id, prompt ]
      else
        [ "codex", "exec", *common, "--sandbox", "workspace-write", "-C", chat.workspace.root_path, prompt ]
      end
    end

    def build_prompt(chat:, message:)
      brief = JSON.generate(WorkspaceChatBrief.build(chat.workspace))
      initial = if chat.session_id.blank?
        <<~TEXT
          You are the persistent operator chat for workspace #{chat.workspace.name}.
          Your filesystem authority is limited to #{chat.workspace.root_path}. You may inspect and modify that worktree when the operator asks.
          Use only the workspace_chat MCP tools for orchestrator state and operations; never access SQLite directly or act on another workspace.
          Answer operational questions from fresh tool state, not remembered state. Explain mutations before or as you perform them.
        TEXT
      end
      <<~PROMPT
        #{initial}
        Fresh Rails observability brief (current, curated): #{brief}

        Operator message: #{message}
      PROMPT
    end

    def parse(output, require_session_id:)
      session_id = nil
      response = nil
      usage = {}
      output.each_line do |line|
        event = JSON.parse(line)
        session_id ||= event["thread_id"] || event.dig("thread", "id") if event["type"].to_s.match?(/thread.*started/)
        item = event["item"]
        response = item["text"] if item.is_a?(Hash) && item["type"] == "agent_message" && item["text"].present?
        response ||= event["message"] if event["type"] == "agent_message" && event["message"].is_a?(String)
        usage = event["usage"] if event["type"].to_s.match?(/turn.*completed/) && event["usage"].is_a?(Hash)
      rescue JSON::ParserError
        next
      end
      raise Error, "Workspace chat returned no assistant message" if response.blank?
      raise Error, "Workspace chat returned no resumable session id" if require_session_id && session_id.blank?

      { session_id:, response:, usage: }
    end

    def workspace_chat_mcp_url
      "#{WorkerSpawner.rails_mcp_url}/workspace-chat"
    end
    private_class_method :workspace_chat_mcp_url
  end
end

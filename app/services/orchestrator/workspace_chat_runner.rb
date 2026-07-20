require "open3"
require "tempfile"

module Orchestrator
  module WorkspaceChatRunner
    class Error < StandardError; end

    module_function

    CLAUDE_MODEL = "sonnet"
    CODEX_MODEL = WorkerSpawner::CODEX_WORKER_MODEL
    RECENT_MESSAGE_LIMIT = 20
    CLAUDE_TOOLS = "Bash,Read,Edit,Write,Grep,Glob,ToolSearch"

    def call(chat:, message:, command_runner: Open3.method(:capture3))
      token = WorkspaceChatCapability.issue(chat)
      prompt = build_prompt(chat:, message:)
      if chat.launcher_variant == "claude"
        run_claude(chat:, prompt:, token:, command_runner:)
      else
        run_codex(chat:, prompt:, token:, command_runner:)
      end
    end

    def run_claude(chat:, prompt:, token:, command_runner:)
      Tempfile.create([ "workspace-chat-mcp", ".json" ]) do |mcp_file|
        mcp_file.chmod(0o600)
        mcp_file.write(JSON.generate({
          mcpServers: { workspace_chat: {
            type: "http", url: workspace_chat_mcp_url,
            headers: { Authorization: "Bearer #{token}" }
          } }
        }))
        mcp_file.flush
        args = [
          "claude", "--model", CLAUDE_MODEL, "--print", "--output-format", "json",
          "--tools", CLAUDE_TOOLS, "--permission-mode", "dontAsk", "--disable-slash-commands",
          "--mcp-config", mcp_file.path, "--strict-mcp-config",
          "--no-session-persistence", "--", prompt
        ]
        stdout, stderr, status = command_runner.call(WorkerSpawner.build_worker_env, *args, chdir: chat.workspace.root_path)
        raise Error, "Workspace chat exited #{status.exitstatus}: #{stderr.presence || stdout}" unless status.success?

        envelope = JSON.parse(stdout)
        response = envelope["result"]
        raise Error, "Workspace chat returned no assistant message" if response.blank?

        { response:, usage: usage_from_claude(envelope) }
      end
    rescue JSON::ParserError => e
      raise Error, "Workspace chat returned invalid JSON: #{e.message}"
    end

    def run_codex(chat:, prompt:, token:, command_runner:)
      args = [
        "codex", "exec", "--model", CODEX_MODEL, "--json", "--ignore-user-config",
        "-c", 'sandbox_mode="workspace-write"',
        "-c", "mcp_servers.workspace_chat.url=\"#{workspace_chat_mcp_url}\"",
        "-c", 'mcp_servers.workspace_chat.bearer_token_env_var="WORKSPACE_CHAT_TOKEN"',
        "--sandbox", "workspace-write", "-C", chat.workspace.root_path, prompt
      ]
      env = WorkerSpawner.build_worker_env.merge("WORKSPACE_CHAT_TOKEN" => token)
      stdout, stderr, status = command_runner.call(env, *args, chdir: chat.workspace.root_path)
      raise Error, "Workspace chat exited #{status.exitstatus}: #{stderr.presence || stdout}" unless status.success?

      parse_codex(stdout)
    end

    def build_prompt(chat:, message:)
      brief = JSON.generate(WorkspaceChatBrief.build(chat.workspace))
      transcript = chat.messages.where(status: "completed").order(:created_at).last(RECENT_MESSAGE_LIMIT).map do |m|
        "#{m.role == "user" ? "Operator" : "Assistant"}: #{m.content}"
      end.join("\n\n")
      <<~PROMPT
        You are the persistent operator chat for workspace #{chat.workspace.name}.
        Your filesystem authority is limited to #{chat.workspace.root_path}. You may inspect and modify that worktree when the operator asks.
        Use only the workspace_chat MCP tools for orchestrator state and operations; never access SQLite directly or act on another workspace.
        Answer operational questions from fresh tool state, not remembered state. Explain mutations before or as you perform them.

        Fresh Rails observability brief (current, curated): #{brief}
        #{"\nRecent conversation:\n#{transcript}\n" if transcript.present?}
        Operator message: #{message}
      PROMPT
    end

    def parse_codex(output)
      response = nil
      usage = {}
      output.each_line do |line|
        event = JSON.parse(line)
        item = event["item"]
        response = item["text"] if item.is_a?(Hash) && item["type"] == "agent_message" && item["text"].present?
        response ||= event["message"] if event["type"] == "agent_message" && event["message"].is_a?(String)
        usage = event["usage"] if event["type"].to_s.match?(/turn.*completed/) && event["usage"].is_a?(Hash)
      rescue JSON::ParserError
        next
      end
      raise Error, "Workspace chat returned no assistant message" if response.blank?

      { response:, usage: }
    end
    private_class_method :parse_codex

    def usage_from_claude(envelope)
      usage = envelope["usage"] || {}
      {
        input_tokens: usage["input_tokens"], output_tokens: usage["output_tokens"],
        cache_read_input_tokens: usage["cache_read_input_tokens"], total_cost_usd: envelope["total_cost_usd"]
      }.compact
    end
    private_class_method :usage_from_claude

    def workspace_chat_mcp_url
      "#{WorkerSpawner.rails_mcp_url}/workspace-chat"
    end
    private_class_method :workspace_chat_mcp_url
  end
end

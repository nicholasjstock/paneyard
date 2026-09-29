require "json"
require "securerandom"
require_relative "../workflow_sandbox/mcp_client"

module FakeHerdr
  # The process FakeHerdr::Server launches in place of claude/codex/opencode.
  # No model: it becomes "ready", takes the prompt herdr's agent.prompt hands
  # it, and does what a directive in that prompt says -- by default, report
  # `done` through the real /mcp/run endpoint with the capability the session
  # was launched with, exactly as a real CLI's MCP client would.
  #
  # Directives, written anywhere in the run's task as `[fake-agent: <mode>]`
  # (FAKE_AGENT_MODE sets the default):
  #
  #   done | blocked | failed  report that outcome and go idle
  #   dirty                    leave an uncommitted file in the worktree, then report done
  #   crash                    exit without reporting (RunSessionReconcileJob's case)
  #   manual                   go idle without reporting; the caller reports itself
  #   working                  stay "working" without reporting, as a CLI mid-task
  #
  # `[fake-agent-prompt: unsubmitted]` reproduces a prompt agent.prompt typed
  # but never submitted (run-20260929-191533-d44e): the agent flickers to
  # "working" for a moment, drops back to idle with the text still "in its
  # input box", and only acts on it once an Enter arrives through
  # agent.send_keys.
  #
  # Its stdout is the fake herdr's control channel: `{"fake_herdr": {...}}`
  # lines update what agent.get says, anything else lands in the pane text.
  class Agent
    DIRECTIVE = /\[fake-agent:\s*([a-z]+)\]/
    UNSUBMITTED = /\[fake-agent-prompt:\s*unsubmitted\]/
    MODES = %w[done blocked failed dirty crash manual working].freeze

    def initialize(argv: ARGV, env: ENV, input: $stdin, output: $stdout)
      @argv = argv
      @env = env
      @input = input
      @output = output
      @output.sync = true
    end

    def run
      trap("TERM") { exit 0 }
      sleep 0.1
      control(status: "idle", ready: true, session: "fake-#{SecureRandom.hex(4)}")
      @input.each_line do |line|
        message = JSON.parse(line)
        case message["type"]
        when "prompt" then receive_prompt(message["text"].to_s)
        when "keys" then handle_keys(Array(message["keys"]))
        end
      end
    end

    private

    def receive_prompt(text)
      return handle_prompt(text) unless text.match?(UNSUBMITTED)

      control(status: "working")
      sleep 0.05
      control(status: "idle")
      @unsubmitted = text
      say("fake agent left a #{text.length}-character prompt unsubmitted")
    end

    def handle_keys(keys)
      say("(keys #{keys.join(' ')})")
      return unless keys.include?("Enter") && @unsubmitted

      text, @unsubmitted = @unsubmitted, nil
      handle_prompt(text)
    end

    def handle_prompt(text)
      control(status: "working")
      mode = text[DIRECTIVE, 1] || @env.fetch("FAKE_AGENT_MODE", "done")
      say("fake agent received a #{text.length}-character prompt; mode #{mode}")
      # A moment of "working", as a real CLI shows. Not the whole of
      # SessionLauncher.submit_prompt_if_unsent!'s window, so a launch usually
      # ends with its (harmless) Enter on an empty input box.
      sleep 0.6

      case mode
      when "done", "blocked", "failed" then report(mode)
      when "dirty"
        File.write("FAKE_AGENT_CHANGES.md", "Left uncommitted by the fake agent.\n")
        report("done")
      when "crash"
        say("fake agent crashing without reporting")
        exit 3
      when "manual" then nil
      when "working" then return
      else say("unknown fake-agent mode #{mode.inspect}; expected one of #{MODES.join(', ')}")
      end
      control(status: "idle")
    end

    def report(outcome)
      url, token = mcp_endpoint
      result = WorkflowSandbox::McpClient.new(url, token:).call_tool(
        "report_idle", outcome:, summary: "Fake agent reported `#{outcome}` from #{Dir.pwd}."
      )
      say("report_idle #{outcome}: #{result.to_json}")
    rescue StandardError => error
      say("report_idle failed: #{error.class}: #{error.message}")
    end

    # Claude's launch args carry the MCP config file RunSessionRunner wrote,
    # so read the URL and bearer from there, as claude would.
    def mcp_endpoint
      config_path = @argv[@argv.index("--mcp-config") + 1] if @argv.include?("--mcp-config")
      if config_path && File.exist?(config_path)
        server = JSON.parse(File.read(config_path)).dig("mcpServers", "workflow")
        return [ server.fetch("url"), server.dig("headers", "Authorization").to_s.delete_prefix("Bearer ") ]
      end

      [ @env.fetch("FAKE_AGENT_MCP_URL"), @env.fetch("WORKFLOW_RUN_TOKEN") ]
    end

    def control(**update)
      @output.puts(JSON.generate("fake_herdr" => update))
    end

    def say(text)
      @output.puts(text)
    end
  end
end

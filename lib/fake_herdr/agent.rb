require "digest"
require "fileutils"
require "json"
require "securerandom"
require "tmpdir"
require_relative "../paneyard_sandbox/mcp_client"

module FakeHerdr
  # The process FakeHerdr::Server launches in place of claude or codex.
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
  # Like claude, it keeps each conversation it starts under the directory it
  # ran in (FAKE_AGENT_CONVERSATIONS_DIR, which FakeHerdr::Server sets), and
  # resumes one when launched with claude's `--resume <id>` or codex's
  # `resume <id>`. A resume of a conversation that directory never had exits
  # at once, before herdr can see it start, as `claude --resume` does.
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
      session = conversation
      sleep 0.1
      control(status: "idle", ready: true, session:)
      @input.each_line do |line|
        message = JSON.parse(line)
        case message["type"]
        when "prompt" then receive_prompt(message["text"].to_s)
        when "keys" then handle_keys(Array(message["keys"]))
        end
      end
    end

    private

    # The conversation id this launch runs: the one it resumes, or a new one.
    def conversation
      resume_id = @argv[@argv.index("--resume") + 1] if @argv.include?("--resume")
      resume_id ||= @argv[1] if @argv.first == "resume"
      if resume_id
        unless File.exist?(conversation_path(resume_id))
          say("No conversation found with session ID: #{resume_id}")
          exit 1
        end
        say("fake agent resumed conversation #{resume_id}")
        return resume_id
      end

      "fake-#{SecureRandom.hex(4)}".tap do |id|
        path = conversation_path(id)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "")
      end
    end

    def conversation_path(id)
      root = @env["FAKE_AGENT_CONVERSATIONS_DIR"].to_s
      root = File.join(Dir.tmpdir, "fake-agent-conversations") if root.empty?
      File.join(root, Digest::SHA256.hexdigest(File.realpath(Dir.pwd)), File.basename(id))
    end

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
      # ends with its (harmless) Enter on an empty input box -- but long
      # enough, at its real 0.5 s sampling, to count as sustained work, which
      # is what spares the launch the retried Enters meant for a prompt that
      # was never picked up. Specs, sampling far faster, shorten it.
      sleep Float(@env.fetch("FAKE_AGENT_WORK_SECONDS", "2.5"))

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
      result = PaneyardSandbox::McpClient.new(url, token:).call_tool(
        "report_idle", outcome:, summary: "Fake agent reported `#{outcome}` from #{Dir.pwd}."
      )
      say("report_idle #{outcome}: #{result.to_json}")
    rescue StandardError => error
      say("report_idle failed: #{error.class}: #{error.message}")
    end

    # Read the URL and bearer from the launch args, as the real CLI would:
    # claude's point at the MCP config file RunSessionRunner wrote; codex's
    # carry them as -c overrides. Sessions get nothing in their environment.
    def mcp_endpoint
      config_path = @argv[@argv.index("--mcp-config") + 1] if @argv.include?("--mcp-config")
      if config_path && File.exist?(config_path)
        server = JSON.parse(File.read(config_path)).dig("mcpServers", "paneyard")
        return [ server.fetch("url"), server.dig("headers", "Authorization").to_s.delete_prefix("Bearer ") ]
      end

      overrides = @argv.each_cons(2).select { |flag, _| flag == "-c" }.map(&:last)
      url = overrides.find { |value| value.start_with?("mcp_servers.paneyard.url=") }
      headers = overrides.find { |value| value.start_with?("mcp_servers.paneyard.http_headers=") }
      raise "no paneyard MCP config in the launch args" unless url && headers

      [ JSON.parse(url.split("=", 2).last), headers[/Bearer ([^"]+)"/, 1] ]
    end

    def control(**update)
      @output.puts(JSON.generate("fake_herdr" => update))
    end

    def say(text)
      @output.puts(text)
    end
  end
end

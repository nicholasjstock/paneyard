require "io/console"
require "json"
require "rbconfig"
require "tempfile"
require_relative "../paneyard_plugin"

module PaneyardPlugin
  # Every command in herdr-plugin.toml, reached through bin/herdr-plugin
  # (which finds the Ruby first). The *-ui commands run inside herdr popups:
  # line-based prompts, since an action's own output only ever reaches
  # `herdr plugin log list`.
  class Cli
    DRIVERS = %w[claude codex].freeze

    USAGE = <<~TEXT.freeze
      Usage: bin/herdr-plugin <command>

        build        install gems into vendor/bundle ([[build]], once per install)
        startup      start Paneyard if it is not running ([[startup]])
        start | restart | stop | status
        url          print the web UI's URL
        mcp-url      print /mcp/admin's URL (and show it as a herdr notification)
        open         open the web UI (this run's page, inside a run's herdr workspace)
        queue-ui | runs-ui | report-ui | close-ui | mcp-ui
                     the interactive popups behind the plugin's actions
    TEXT

    def self.start(argv, env: ENV)
      new(env:).call(argv)
    end

    def initialize(env: ENV, out: $stdout, input: $stdin)
      @env = env
      @out = out
      @in = input
      @paths = Paths.new(env:)
    end

    def call(argv)
      command = argv.first.to_s.tr("_", "-")
      case command
      when "build" then build
      when "startup", "start" then start
      when "restart" then restart
      when "stop" then stop
      when "status" then status
      when "url" then puts(running!.url)
      when "mcp-url" then mcp_url
      when "open" then open
      when "queue-ui" then interactive { queue_ui }
      when "runs-ui" then interactive { runs_ui }
      when "report-ui" then interactive { this_run_ui(:report) }
      when "close-ui" then interactive { this_run_ui(:close) }
      when "mcp-ui" then interactive { mcp_ui }
      else
        @out.puts USAGE
        command.empty? || %w[help -h --help].include?(command) ? 0 : 2
      end.then { |status| status.is_a?(Integer) ? status : 0 }
    rescue Error, Client::Error, SystemCallError => error
      warn "paneyard: #{error.message}"
      1
    end

    private

    attr_reader :paths

    # --- lifecycle --------------------------------------------------------

    def build
      bindir = RbConfig::CONFIG["bindir"]
      bundle = File.join(bindir, "bundle")
      bundle = "bundle" unless File.executable?(bundle)
      env = @env.keys.select { |key| key.start_with?("BUNDLE_", "BUNDLER_") }.to_h { |key| [ key, nil ] }
        .merge("PATH" => [ bindir, @env["PATH"] ].compact.join(File::PATH_SEPARATOR), "RUBYOPT" => nil,
          "BUNDLE_GEMFILE" => File.join(paths.app_root, "Gemfile"))
      [
        [ bundle, "config", "set", "--local", "path", "vendor/bundle" ],
        [ bundle, "config", "set", "--local", "without", "development test" ],
        [ bundle, "install", "--jobs", "4" ]
      ].each do |argv|
        puts "paneyard build: #{argv.drop(1).join(' ')}"
        raise Error, "#{argv.join(' ')} failed" unless system(env, *argv, chdir: paths.app_root)
      end
      # Gems with native extensions only load under the Ruby that built them.
      File.write(File.join(paths.app_root, ".paneyard-ruby"), RbConfig.ruby)
      puts "paneyard build: done (Ruby #{RUBY_VERSION} at #{RbConfig.ruby})"
    end

    def start
      result = daemon.ensure_running
      report(result)
      announce(result)
    end

    def restart
      result = daemon.restart
      report(result)
      announce(result)
      notify("Paneyard restarted", result.url)
    end

    def stop
      puts(daemon.stop ? "Paneyard stopped." : "Paneyard was not running.")
      notify("Paneyard stopped", "Any action starts it again.")
    end

    def status
      result = daemon.status
      unless result
        puts "Paneyard is not running. State: #{paths.state_dir}"
        return 3
      end

      puts "Paneyard is running (pid #{result.pid}) at #{result.url}"
      puts "  MCP:    #{result.url}/mcp/admin"
      puts "  herdr:  #{result.herdr_socket || 'default socket'}"
      puts "  state:  #{paths.state_dir}"
      puts "  config: #{paths.env_file}"
      puts "  log:    #{paths.log_file}"
      0
    end

    def mcp_url
      url = "#{running!.url}/mcp/admin"
      puts url
      notify("Paneyard MCP", url)
    end

    def open
      result = running!
      browse(this_run_url(result.url) || result.url)
    end

    # --- popups -------------------------------------------------------------

    def queue_ui
      client = connect!
      dir = context_dir
      raise Error, "herdr did not say which directory this pane is in." unless dir

      repository, current_branch = WorkspaceMatch.repository_of(dir)
      workspaces = client.workspaces
      workspace = WorkspaceMatch.workspace_for(workspaces, dir, repository:) || register!(client, repository || dir)
      return unless workspace

      default = workspace.fetch("defaultBaseBranch")
      heading "Queue a task in #{workspace.fetch('name')}"
      say dim(workspace.fetch("repositoryPath"))
      say ""
      say "Describe the task: the goal, constraints, and how to tell it worked."
      say dim("A blank line queues it. Ctrl-C cancels.")
      task = read_task
      return say("Nothing queued.") if task.empty?

      base_branch = ask_base_branch(default, current_branch)
      driver = ask_driver
      queued = client.queue(task:, workspace: workspace.fetch("name"), base_branch:, driver:)
      capacity = queued.fetch("capacity", {})
      say ""
      say bold("Queued #{queued.fetch('runId')} from #{queued.fetch('baseBranch', base_branch || default)}.")
      behind = queued.fetch("queuedBehind", 0)
      say "#{capacity['inFlight']} of #{capacity['limit']} sessions in use#{behind.positive? ? ", #{behind} queued ahead of it" : ''}. " \
        "Its herdr workspace opens when it starts."
      pause
    end

    # The workspace's default, unless the operator names another branch; the
    # branch this pane is on is offered, since starting from it is the usual
    # reason not to use the default.
    def ask_base_branch(default, current_branch)
      hint = current_branch && current_branch != default ? "; this pane is on #{current_branch}" : ""
      answer = ask("Base branch (Enter for #{default}#{hint}): ")
      answer.nil? || answer.empty? ? nil : answer
    end

    def runs_ui
      client = connect!
      loop do
        entries = run_entries(client)
        heading "Paneyard runs"
        if entries.empty?
          say "No runs yet. Use \"Queue a task here\" in a repository's pane."
        else
          entries.each_with_index { |(workspace, run), index| say run_line(index + 1, workspace, run) }
        end
        say ""
        choice = ask("Number for a run, o to open Paneyard, Enter to refresh, q to quit: ")
        case choice
        when nil, "q" then return
        when "o" then browse(@url)
        when /\A\d+\z/
          workspace, run = entries[choice.to_i - 1]
          next say("No run #{choice}.") unless run
          return if run_screen(client, workspace, run.fetch("runId")) == :quit
        end
      end
    end

    # The report and close actions, for the run whose herdr workspace the
    # action was invoked in.
    def this_run_ui(mode)
      client = connect!
      workspace, run = WorkspaceMatch.run_in_herdr_workspace(client.runs, herdr_workspace_id)
      unless run
        say "This herdr workspace is not a Paneyard run's."
        return mode == :report ? runs_ui : pause
      end

      if mode == :report
        return run_screen(client, workspace, run.fetch("runId")) == :back ? runs_ui : nil
      end

      close!(client, workspace, client.run(run.fetch("runId"), workspace: workspace.fetch("name")))
      pause
    end

    def mcp_ui
      connect!
      url = "#{@url}/mcp/admin"
      heading "Connect Claude Code to Paneyard"
      say "Paneyard's MCP endpoint is #{bold(url)}"
      say ""
      say "Register it for every project with:"
      say "  claude mcp add --transport http -s user paneyard #{url}"
      say dim("This port stays the same across restarts. If it ever has to change, Paneyard says so.")
      say dim("Registered it before under another name (earlier docs used paneyard-admin)? Remove that one:")
      say dim("  claude mcp remove -s user paneyard-admin")
      unless executable?("claude")
        say ""
        say "(claude is not on this PATH, so run that line yourself.)"
        return pause
      end

      say ""
      return unless ask("Register it now, replacing any existing \"paneyard\" entry? [y/N] ")&.downcase == "y"

      system("claude", "mcp", "remove", "-s", "user", "paneyard", out: File::NULL, err: File::NULL)
      ok = system("claude", "mcp", "add", "--transport", "http", "-s", "user", "paneyard", url)
      say(ok ? "Registered. New Claude Code sessions have Paneyard's tools." : "claude mcp add failed; see above.")
      pause
    end

    # A run's detail and newest report. Returns :quit to leave the popup.
    def run_screen(client, workspace, run_id)
      loop do
        run = client.run(run_id, workspace: workspace.fetch("name"))
        session = run["session"] || {}
        live = session["live"]
        heading "#{run.fetch('runId')} · #{run.fetch('status')}#{" · agent #{session['agentStatus']}" if live && session['agentStatus']}"
        say dim("#{workspace.fetch('name')} · #{run['driver']} · #{run['branch'] || 'no branch yet'} from #{run['baseBranch']}")
        say dim(run["worktree"]) if run["worktree"]
        say "Launch error: #{run['launchError']}" if run["launchError"]
        show_report(run)
        say ""
        options = []
        options << "f to go to its herdr workspace" if live && session["herdrWorkspace"]
        options << "c to close its session" if live
        options += [ "o to open it in the browser", "r to re-read", "b back", "q quit" ]
        case ask("#{options.join(', ')}: ")
        when nil, "q" then return :quit
        when "b" then return :back
        when "o" then browse(run_url(workspace, run))
        when "f"
          next unless live && session["herdrWorkspace"]

          herdr("workspace", "focus", session["herdrWorkspace"])
          return :quit
        when "c"
          next unless live

          close!(client, workspace, run)
          pause
          return :quit
        end
      end
    end

    def show_report(run)
      checkpoint = Array(run["checkpoints"]).last
      unless checkpoint
        say ""
        say dim("No report yet.")
        return
      end

      text = "#{checkpoint['outcome']&.upcase} report, #{checkpoint['at']}\n\n#{checkpoint['summary']}"
      rows = (IO.console&.winsize&.first || 24)
      if text.lines.count > rows - 8 && executable?("less") && @out.tty?
        Tempfile.create([ "paneyard-report", ".md" ]) do |file|
          file.write(text)
          file.flush
          system("less", "-R", "-P", "Report (q to go back)", file.path)
        end
        say ""
        say dim("(report shown in less)")
      else
        say ""
        say text
      end
    end

    def close!(client, workspace, run)
      say ""
      say "Closing the session quits its agent and closes its herdr workspace. Its worktree is removed only if its"
      say "work is saved (in #{run['baseBranch'] || 'its base branch'}, or pushed)."
      return say("Left it running.") unless ask("Close #{run.fetch('runId')}'s session? [y/N] ")&.downcase == "y"

      closed = client.close(run.fetch("runId"), workspace: workspace.fetch("name"))
      say bold("Closed. Run #{closed.fetch('status')}.")
      case closed["worktree"]
      when "removed" then say "Removed its worktree #{closed['worktreeName']} (the branch is kept)."
      when "kept" then say "Kept its worktree #{closed['worktreeName']}: it has uncommitted or unpushed work."
      else say "Could not check its worktree: #{closed['worktreeError']}"
      end
    end

    def register!(client, path)
      say "#{path} is not in a Paneyard workspace yet. Registering it…"
      workspace = client.register(path:)
      say "Registered #{workspace.fetch('name')} (#{workspace.fetch('repositoryPath')}), whose runs start from " \
        "#{workspace.fetch('defaultBaseBranch')} by default."
      say ""
      workspace
    rescue PaneyardSandbox::McpClient::ToolError => error
      problems = Array(error.payload["problems"]).filter_map { |problem| problem["message"] }
      say ""
      if problems.empty?
        say error.payload["message"] || error.message
      else
        say "Paneyard can't use this as a workspace yet. Nothing was changed. To fix it:"
        problems.each_with_index { |problem, index| say "#{index + 1}. #{problem}" }
        say ""
        say "Then queue the task again."
      end
      pause
      nil
    end

    def run_entries(client)
      client.runs.flat_map { |workspace, listed| listed.fetch("runs").map { |run| [ workspace, run ] } }
        .sort_by { |_workspace, run| run["startedAt"] || "9999" }.reverse.first(40)
    end

    def run_line(number, workspace, run)
      width = IO.console&.winsize&.last || 100
      session = run["session"] || {}
      state = session["live"] && session["agentStatus"] ? "#{run['status']}/#{session['agentStatus']}" : run["status"]
      line = format("%3d  %-4s  %-18s  %-8s  %-14s  ", number, run.fetch("runId")[-4..], state, run["driver"],
        workspace.fetch("name")[0, 14])
      line + run["task"].to_s.lines.first.to_s.strip[0, [ width - line.length - 1, 10 ].max]
    end

    def read_task
      lines = []
      while (line = @in.gets)
        break if line.strip.empty? && lines.any?
        next if line.strip.empty?

        lines << line.chomp
      end
      lines.join("\n").strip
    end

    def ask_driver
      loop do
        answer = ask("Agent: #{DRIVERS.join(', ')} (Enter for claude): ")
        return nil if answer.nil? || answer.empty?
        return answer if DRIVERS.include?(answer)

        say "Not one of #{DRIVERS.join(', ')}."
      end
    end

    # --- daemon, herdr and the browser -----------------------------------

    def daemon
      @daemon ||= Daemon.new(paths:, env: @env)
    end

    # Starts the daemon if need be, and returns a client for it.
    def connect!
      say dim("Starting Paneyard…") unless daemon.status
      result = daemon.ensure_running
      announce(result)
      @url = result.url
      Client.new(result.url)
    end

    def running!
      daemon.ensure_running.tap { |result| announce(result) }
    end

    def report(result)
      verb = { running: "is running", started: "started", restarted: "restarted", elsewhere: "is running" }.fetch(result.outcome)
      puts "Paneyard #{verb} (pid #{result.pid}) at #{result.url}. State: #{paths.state_dir}"
    end

    # Tell the operator about what they would otherwise only find in a log.
    def announce(result)
      if result.outcome == :elsewhere
        warn "paneyard: running for another herdr server (#{result.herdr_socket}); its sessions open there. " \
          "The restart action moves it to this one."
      end
      return unless result.port_changed?

      notify("Paneyard moved to port #{result.port}",
        "Port #{result.previous_port} was taken. Re-register MCP: #{result.url}/mcp/admin (action: Connect Claude Code)")
    end

    def this_run_url(base)
      client = Client.new(base)
      workspace, run = WorkspaceMatch.run_in_herdr_workspace(client.runs, herdr_workspace_id)
      run && run_url(workspace, run, base)
    rescue Client::Error
      nil
    end

    def run_url(workspace, run, base = @url)
      "#{base}/workspaces/#{workspace.fetch('id')}/runs/#{run.fetch('runId')}"
    end

    def browse(url)
      opener = RbConfig::CONFIG["host_os"].include?("darwin") ? "open" : "xdg-open"
      system(opener, url, out: File::NULL, err: File::NULL) || puts(url)
    end

    def notify(title, body)
      herdr("notification", "show", title, "--body", body)
    end

    def herdr(*args)
      system(@env["HERDR_BIN_PATH"].to_s.empty? ? "herdr" : @env["HERDR_BIN_PATH"], *args, out: File::NULL, err: File::NULL)
    rescue SystemCallError
      false
    end

    def context
      @context ||= JSON.parse(@env["HERDR_PLUGIN_CONTEXT_JSON"].to_s.empty? ? "{}" : @env["HERDR_PLUGIN_CONTEXT_JSON"])
    rescue JSON::ParserError
      @context = {}
    end

    def context_dir
      [ context["focused_pane_cwd"], context["workspace_cwd"] ].find { |dir| dir.is_a?(String) && !dir.empty? }
    end

    def herdr_workspace_id
      context["workspace_id"] || @env["HERDR_WORKSPACE_ID"]
    end

    def executable?(name)
      @env["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, name)) }
    end

    # --- terminal -------------------------------------------------------------

    # A popup closes the moment its command exits, so an error has to wait
    # for a key or nobody sees it.
    def interactive
      yield
      0
    rescue Interrupt
      0
    rescue Error, Client::Error, SystemCallError => error
      say ""
      say "Paneyard: #{error.message}"
      pause
      1
    end

    def ask(prompt)
      @out.print(prompt)
      @out.flush
      @in.gets&.strip
    end

    def pause
      ask(dim("Press Enter to close."))
      nil
    end

    def heading(text)
      say ""
      say bold(text)
    end

    def say(text)
      @out.puts(text)
    end
    alias_method :puts, :say

    def bold(text) = style(text, 1)
    def dim(text) = style(text, 2)

    def style(text, code)
      @out.tty? ? "\e[#{code}m#{text}\e[0m" : text
    end
  end
end

exit PaneyardPlugin::Cli.start(ARGV) if $PROGRAM_NAME == __FILE__

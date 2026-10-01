require "io/console"
require "json"
require "open3"
require "shellwords"
require "tempfile"
require "yaml"
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

        startup      start Paneyard if it is not running ([[startup]])
        start | restart | stop | status
        url          print the daemon's base URL
        mcp-url      print /mcp/admin's URL (and show it as a herdr notification)
        menu-ui | queue-ui | runs-ui | report-ui | close-ui | layout-ui | setup-ui | mcp-ui
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
      when "startup", "start" then start
      when "restart" then restart
      when "stop" then stop
      when "status" then status
      when "url" then puts(running!.url)
      when "mcp-url" then mcp_url
      when "menu-ui" then interactive { menu_ui }
      when "queue-ui" then interactive { queue_ui }
      when "runs-ui" then interactive { runs_ui }
      when "report-ui" then interactive { this_run_ui(:report) }
      when "close-ui" then interactive { this_run_ui(:close) }
      when "layout-ui" then interactive { layout_ui }
      when "setup-ui", "mcp-ui" then interactive { mcp_ui }
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

    def layout_ui
      client = connect!
      dir = context_dir
      raise Error, "herdr did not say which directory this pane is in." unless dir

      repository, = WorkspaceMatch.repository_of(dir)
      workspace = WorkspaceMatch.workspace_for(client.workspaces, dir, repository:)
      unless workspace
        say "This pane is not inside a registered Paneyard workspace."
        return pause
      end

      default = workspace.fetch("defaultLayoutYaml")
      data = YAML.safe_load(workspace["layoutYaml"] || default)
      loop do
        render_layout(workspace.fetch("name"), data)
        choice = ask("[a] add pane  [t] add tab  [e] edit  [d] delete pane  [k] delete tab  [r] reset  [y] YAML  [s] save  [q] cancel: ")&.downcase
        case choice
        when "a" then add_layout_pane(data)
        when "t" then add_layout_tab(data)
        when "e" then edit_layout_pane(data)
        when "d" then delete_layout_pane(data)
        when "k" then delete_layout_tab(data)
        when "r" then data = YAML.safe_load(default)
        when "y" then data = edit_layout_yaml(data)
        when "s"
          layout = YAML.dump(data).delete_prefix("---\n")
          layout = "" if data == YAML.safe_load(default)
          saved = client.update_layout(workspace: workspace.fetch("name"), layout:)
          say bold(saved.fetch("usingDefault") ? "Reset to the default layout." : "Saved the layout.")
          return pause
        when nil, "", "q" then return say("Nothing changed.")
        else say "Unknown choice."
        end
      rescue PaneyardSandbox::McpClient::ToolError => error
        say ""
        say "The layout was not saved:"
        Array(error.payload["problems"]).each { |problem| say "- #{problem}" }
        say(error.payload["message"] || error.message) if Array(error.payload["problems"]).empty?
      end
    end

    def render_layout(name, data)
      heading "#{name} layout"
      Array(data["tabs"]).each_with_index do |tab, tab_index|
        say bold("Tab #{tab_index + 1}: #{tab['name'].to_s.empty? ? '(unnamed)' : tab['name']}")
        Array(tab["panes"]).each_with_index do |entry, pane_index|
          pane = layout_pane(entry)
          split = pane["split"]
          branch = pane_index == Array(tab["panes"]).length - 1 ? "└─" : "├─"
          detail = if split
            "#{split.fetch('direction', 'right')} of #{split['of']}#{split['ratio'] ? " @ #{split['ratio']}" : ''}"
          else
            "root"
          end
          command = pane["command"].to_s.empty? ? "" : " · #{pane['command']}"
          say "  #{tab_index + 1}.#{pane_index + 1} #{branch} #{pane['name']} [#{detail}]#{command}"
        end
      end
      say ""
    end

    def add_layout_pane(data)
      tabs = Array(data["tabs"])
      tab = choose_layout_tab(tabs)
      return unless tab

      panes = Array(tab["panes"])
      name = ask("Pane name: ")
      return say("A pane needs a name.") if name.to_s.empty?

      pane = { "name" => name, "command" => ask("Command (blank for a shell): ").to_s }
      unless panes.empty?
        say "Split from: #{panes.map.with_index(1) { |entry, index| "#{index}=#{layout_pane(entry)['name']}" }.join(', ')}"
        source_number = ask("Pane number: ").to_i
        source = panes[source_number - 1] if source_number.positive?
        return say("No such pane.") unless source

        direction = ask("Direction [right/down] (right): ")
        ratio = ask("Ratio 0.1–0.9 (blank for automatic): ")
        split = { "of" => layout_pane(source)["name"], "direction" => direction.to_s.empty? ? "right" : direction }
        split["ratio"] = ratio.to_f unless ratio.to_s.empty?
        pane["split"] = split
      end
      pane.delete("command") if pane["command"].empty?
      panes << pane
      tab["panes"] = panes
    end

    def add_layout_tab(data)
      name = ask("Tab name (blank for unnamed): ")
      pane_name = ask("Root pane name: ")
      return say("A root pane needs a name.") if pane_name.to_s.empty?

      pane = { "name" => pane_name, "command" => ask("Command (blank for a shell): ").to_s }
      pane.delete("command") if pane["command"].empty?
      tab = { "panes" => [ pane ] }
      tab["name"] = name unless name.to_s.empty?
      data["tabs"] << tab
    end

    def edit_layout_pane(data)
      tab, index, pane = choose_layout_pane(data)
      return unless pane
      return say("The agent pane is fixed.") if pane["name"] == "agent"

      old_name = pane["name"]
      name = ask("Name (#{old_name}): ")
      pane["name"] = name unless name.to_s.empty?
      command = ask("Command (#{pane['command'] || 'shell'}; '-' clears): ")
      pane["command"] = command == "-" ? nil : command unless command.to_s.empty?
      pane.delete("command") if pane["command"].to_s.empty?
      if index.positive?
        earlier = Array(tab["panes"])[0...index]
        split = pane["split"] ||= { "of" => layout_pane(earlier.first)["name"], "direction" => "right" }
        say "Split from: #{earlier.map.with_index(1) { |entry, position| "#{position}=#{layout_pane(entry)['name']}" }.join(', ')}"
        source = ask("Pane number (#{split['of']}): ")
        split["of"] = layout_pane(earlier[source.to_i - 1])["name"] if source.to_i.positive? && earlier[source.to_i - 1]
        direction = ask("Direction right/down (#{split.fetch('direction', 'right')}): ")
        split["direction"] = direction unless direction.to_s.empty?
        ratio = ask("Ratio 0.1–0.9 (#{split['ratio'] || 'automatic'}; '-' clears): ")
        split["ratio"] = ratio.to_f unless ratio.to_s.empty? || ratio == "-"
        split.delete("ratio") if ratio == "-"
      end
      Array(tab["panes"])[(index + 1)..]&.each do |entry|
        split = layout_pane(entry)["split"]
        split["of"] = pane["name"] if split && split["of"] == old_name
      end
    end

    def delete_layout_pane(data)
      tab, index, pane = choose_layout_pane(data)
      return unless pane
      return say("The agent pane cannot be deleted.") if pane["name"] == "agent"
      return say("A tab's root pane cannot be deleted; delete the tab with [k] instead.") if index.zero?
      if Array(tab["panes"]).any? { |entry| layout_pane(entry).dig("split", "of") == pane["name"] }
        return say("Another pane splits from #{pane['name']}; move or delete that pane first.")
      end

      tab["panes"].delete_at(index)
    end

    def delete_layout_tab(data)
      tabs = Array(data["tabs"])
      return say("The first tab contains the agent and cannot be deleted.") if tabs.one?

      number = ask("Tab number to delete (2-#{tabs.length}): ").to_i
      return say("The first tab contains the agent and cannot be deleted.") if number == 1
      return say("No such tab.") unless number.between?(2, tabs.length)

      tabs.delete_at(number - 1)
    end

    def choose_layout_tab(tabs)
      return tabs.first if tabs.one?

      number = ask("Tab number (1-#{tabs.length}): ").to_i
      tab = tabs[number - 1] if number.positive?
      say("No such tab.") unless tab
      tab
    end

    def choose_layout_pane(data)
      reference = ask("Pane number (for example 1.2): ").to_s
      tab_number, pane_number = reference.split(".", 2).map(&:to_i)
      tab = Array(data["tabs"])[tab_number - 1] if tab_number.positive?
      entry = Array(tab&.fetch("panes", nil))[pane_number - 1] if tab && pane_number.positive?
      say("No such pane.") unless entry
      [ tab, pane_number - 1, entry && layout_pane(entry) ]
    end

    def layout_pane(entry) = entry == "agent" ? { "name" => "agent" } : entry

    def edit_layout_yaml(data)
      Tempfile.create([ "paneyard-layout", ".yml" ]) do |file|
        file.write(YAML.dump(data).delete_prefix("---\n"))
        file.flush
        return data unless system(*editor_command, file.path)

        parsed = YAML.safe_load(File.read(file.path))
        unless parsed.is_a?(Hash) && parsed["tabs"].is_a?(Array)
          say "YAML was not applied: layout must have a `tabs:` list."
          return data
        end

        parsed
      rescue Psych::Exception => error
        say "YAML was not applied: #{error.message}"
        data
      end
    end

    def editor_command
      command = [ @env["VISUAL"], @env["EDITOR"] ].find { |candidate| !candidate.to_s.empty? } || "vi"
      Shellwords.split(command)
    end

    # --- popups -------------------------------------------------------------

    def menu_ui
      heading "Paneyard"
      say "q  Queue a task here"
      say "r  Browse runs and reports"
      say "p  Show this run's report"
      say "x  Close this run's session"
      say "l  Edit this workspace's layout"
      say "s  Configure coding-agent MCP"
      say ""

      case ask("Choose an action (Enter cancels): ")&.downcase
      when "q" then queue_ui
      when "r" then runs_ui
      when "p" then this_run_ui(:report)
      when "x" then this_run_ui(:close)
      when "l" then layout_ui
      when "s" then mcp_ui
      else say "Cancelled."
      end
    end

    def queue_ui
      client = connect!
      dir = context_dir
      raise Error, "herdr did not say which directory this pane is in." unless dir

      repository, current_branch = WorkspaceMatch.repository_of(dir)
      workspaces = client.workspaces
      workspace = WorkspaceMatch.workspace_for(workspaces, dir, repository:) || register!(client, repository || dir)
      return unless workspace

      default = workspace.fetch("defaultBaseBranch")
      clear_screen
      say accent("PANEYARD  /  NEW RUN")
      say rule
      say "#{bold(workspace.fetch('name'))}  #{dim(workspace.fetch('repositoryPath'))}"
      say ""
      say bold("Task")
      say dim("Describe the goal, constraints, and how to tell it worked.")
      say dim("Enter submits  ·  Shift-Enter adds a line  ·  Ctrl-C cancels")
      say ""
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
        choice = ask("Number for a run, Enter to refresh, q to quit: ")
        case choice
        when nil, "q" then return
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
      heading "Connect coding agents to Paneyard"
      say "Paneyard's MCP endpoint is #{bold(url)}"
      say ""
      clients = mcp_clients.select { |client| executable?(client.fetch(:executable)) }
      if clients.empty?
        say "No supported agent CLIs were found on this PATH."
        show_manual_mcp_commands(url)
        return pause
      end

      clients.each { |client| say "✓ #{client.fetch(:label)} detected" }
      say ""
      answer = ask("Configure Paneyard MCP integrations? [Y/n] ")
      unless answer.nil? || answer.empty? || answer.downcase == "y"
        say "No configuration changed."
        show_manual_mcp_commands(url)
        return pause
      end

      clients.each { |client| configure_mcp_client(client, url) }
      say ""
      say dim("New agent sessions will have Paneyard's tools. This setup is safe to run again.")
      pause
    end

    def mcp_clients
      [
        { id: :claude, label: "Claude Code", executable: "claude" },
        { id: :codex, label: "Codex", executable: "codex" }
      ]
    end

    def configure_mcp_client(client, url)
      existing = existing_mcp(client)
      if existing && existing.fetch(:url) == url
        return say "✓ Paneyard MCP already configured for #{client.fetch(:label)}"
      end
      if existing && existing[:scope] && existing.fetch(:scope) != :user
        return say "✗ #{client.fetch(:label)} has a non-user \"paneyard\" entry; left it unchanged."
      end

      if existing
        removed = remove_mcp(client)
        unless removed.fetch(:success)
          detail = removed.fetch(:error).lines.last&.strip
          return say "✗ Could not update #{client.fetch(:label)} because its existing entry could not be removed" \
            "#{detail.to_s.empty? ? '.' : ": #{detail}"}"
        end
      end
      result = add_mcp(client, url)
      if result.fetch(:success)
        say "✓ Paneyard MCP configured for #{client.fetch(:label)}"
      else
        rollback = add_mcp(client, existing.fetch(:url)) if existing
        detail = result.fetch(:error).lines.last&.strip
        message = "✗ Could not configure #{client.fetch(:label)}#{detail.to_s.empty? ? '' : ": #{detail}"}"
        message += rollback&.fetch(:success) ? " (restored its previous entry)." : "."
        say message
      end
    rescue StandardError => error
      say "✗ Could not inspect or configure #{client.fetch(:label)}: #{error.message}"
    end

    def existing_mcp(client)
      case client.fetch(:id)
      when :claude
        result = run_command("claude", "mcp", "get", "paneyard")
        return unless result.fetch(:success)

        scope = result.fetch(:output)[/Scope:\s+([^\n]+)/, 1]
        url = result.fetch(:output)[/URL:\s+(\S+)/, 1]
        raise Error, "Claude Code returned an unrecognized MCP entry" unless url

        { url:, scope: scope&.start_with?("User") ? :user : :other }
      when :codex
        result = run_command("codex", "mcp", "get", "paneyard", "--json")
        return unless result.fetch(:success)

        url = JSON.parse(result.fetch(:output)).dig("transport", "url")
        raise Error, "Codex returned an unrecognized MCP entry" unless url

        { url:, scope: :user }
      end
    end

    def add_mcp(client, url)
      case client.fetch(:id)
      when :claude then run_command("claude", "mcp", "add", "--transport", "http", "-s", "user", "paneyard", url)
      when :codex then run_command("codex", "mcp", "add", "paneyard", "--url", url)
      end
    end

    def remove_mcp(client)
      argv = [ client.fetch(:executable), "mcp", "remove" ]
      argv += [ "-s", "user" ] if client.fetch(:id) == :claude
      run_command(*argv, "paneyard")
    end

    def show_manual_mcp_commands(url)
      say ""
      say "Manual setup:"
      say "  claude mcp add --transport http -s user paneyard #{url}"
      say "  codex mcp add paneyard --url #{url}"
    end

    def run_command(*argv)
      stdout, stderr, status = Open3.capture3(*argv)
      { success: status.success?, output: stdout, error: stderr.empty? ? stdout : stderr }
    rescue SystemCallError => error
      { success: false, output: "", error: error.message }
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
        options += [ "r to re-read", "b back", "q quit" ]
        case ask("#{options.join(', ')}: ")
        when nil, "q" then return :quit
        when "b" then return :back
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
      return read_task_lines unless @in.tty? && @out.tty? && @in.respond_to?(:getch)

      read_task_keys
    end

    # In raw mode Enter and Shift-Enter remain distinct. Most macOS terminals
    # send CR for Enter and LF for Shift-Enter; terminals using the Kitty
    # keyboard protocol send CSI 13;2u for Shift-Enter instead.
    def read_task_keys
      task = +""
      @out.print(accent("› "))
      @out.flush
      @in.raw do
        loop do
          key = @in.getch
          case key
          when "\r"
            @out.puts
            break
          when "\n"
            task << "\n"
            @out.print("\r\n#{accent('› ')}")
          when "\u0003"
            raise Interrupt
          when "\u007f", "\b"
            next if task.empty? || task.end_with?("\n")

            task.chop!
            @out.print("\b \b")
          when "\e"
            sequence = read_escape_sequence
            if sequence == "[13;2u"
              task << "\n"
              @out.print("\r\n#{accent('› ')}")
            end
          else
            task << key
            @out.print(key)
          end
          @out.flush
        end
      end
      task.strip
    end

    def read_escape_sequence
      sequence = +""
      while IO.select([ @in ], nil, nil, 0.01)
        character = @in.getch
        sequence << character
        break if character.match?(/[A-Za-z~]/)
      end
      sequence
    end

    def read_task_lines
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

    # --- daemon and herdr -------------------------------------------------

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

    def clear_screen
      @out.print("\e[2J\e[H") if @out.tty?
    end

    def rule
      width = [ (IO.console&.winsize&.last || 72) - 1, 72 ].min
      dim("─" * [ width, 24 ].max)
    end

    def say(text)
      @out.puts(text)
    end
    alias_method :puts, :say

    def bold(text) = style(text, 1)
    def dim(text) = style(text, 2)
    def accent(text) = style(text, 36)

    def style(text, code)
      @out.tty? ? "\e[#{code}m#{text}\e[0m" : text
    end
  end
end

exit PaneyardPlugin::Cli.start(ARGV) if $PROGRAM_NAME == __FILE__

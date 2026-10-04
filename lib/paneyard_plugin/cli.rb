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
    # How each driver's command line names its model (codex also takes
    # `-c model=...`): the fallback when its session log can't be read, since
    # it misses a /model switch.
    MODEL_FLAGS = { "claude" => %w[--model], "codex" => %w[-m --model] }.freeze
    MODEL_CHOICES_SHOWN = 15

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
      problem = layout_name_problem(data, name)
      return say(problem) if problem

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
      problem = layout_name_problem(data, pane_name)
      return say(problem) if problem

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
      unless name.to_s.empty? || name == old_name
        problem = layout_name_problem(data, name)
        return say(problem) if problem

        pane["name"] = name
      end
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

    # Caught as the name is typed, rather than on save, so nothing else typed
    # for the pane is wasted.
    def layout_name_problem(data, name)
      return "A pane needs a name." if name.to_s.empty?
      return "`agent` is the agent's own pane; give this one another name." if name == "agent"

      taken = Array(data["tabs"]).flat_map { |tab| Array(tab["panes"]).map { |entry| layout_pane(entry)["name"] } }
      "There is already a pane named #{name}." if taken.include?(name)
    end

    def edit_layout_yaml(data)
      Tempfile.create([ "paneyard-layout", ".yml" ]) do |file|
        file.write(YAML.dump(data).delete_prefix("---\n"))
        file.flush
        return data unless system(*editor_command, file.path)

        parsed = YAML.safe_load(File.read(file.path))
        problem = layout_shape_problem(parsed)
        if problem
          say "YAML was not applied: #{problem}"
          return data
        end

        parsed
      rescue Psych::Exception => error
        say "YAML was not applied: #{error.message}"
        data
      end
    end

    # Only the shape the builder itself needs; whether the layout is valid is
    # the server's call, on save.
    def layout_shape_problem(parsed)
      return "layout must have a `tabs:` list." unless parsed.is_a?(Hash) && parsed["tabs"].is_a?(Array) && parsed["tabs"].any?

      parsed["tabs"].each_with_index do |tab, index|
        return "tab #{index + 1} must be a mapping with a `panes:` list." unless tab.is_a?(Hash) && tab["panes"].is_a?(Array)
        unless tab["panes"].all? { |pane| pane == "agent" || (pane.is_a?(Hash) && pane["name"].is_a?(String)) }
          return "every pane in tab #{index + 1} must be `agent` or a mapping with a `name:`."
        end
      end
      nil
    end

    def editor_command
      command = [ @env["VISUAL"], @env["EDITOR"] ].find { |candidate| !candidate.to_s.empty? } || "vi"
      Shellwords.split(command)
    end

    # --- popups -------------------------------------------------------------

    def menu_ui
      heading "Paneyard"
      say "q  Hand off a task"
      say "r  Jobs and reports"
      say "p  This job's report"
      say "x  Close this job"
      say "l  Job layout for this repository"
      say "s  Let your agents queue jobs"
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
      pane_driver, pane_model, pane_switch = pane_agent
      workspaces = client.workspaces
      registered = false
      workspace = WorkspaceMatch.workspace_for(workspaces, dir, repository:) ||
        register!(client, repository || dir).tap { |found| registered = !found.nil? }
      return unless workspace

      default = current_branch || workspace.fetch("defaultBaseBranch")
      clear_screen
      say accent("PANEYARD  /  NEW RUN")
      say rule
      say "#{bold(workspace.fetch('name'))}  #{dim(workspace.fetch('repositoryPath'))}"
      say dim("Registered as a new workspace; runs start from #{default} by default.") if registered
      say ""
      say bold("Task")
      say dim("Describe the goal, constraints, and how to tell it worked.")
      say dim("Enter submits  ·  Shift-Enter adds a line  ·  Ctrl-C cancels")
      say ""
      task = read_task
      return say("Nothing queued.") if task.empty?

      base_branch = ask_base_branch(default, workspace.fetch("defaultBaseBranch"))
      driver = ask_driver(pane_driver)
      same_agent = driver == pane_driver
      model = ask_model(client, workspace, driver || "claude", same_agent ? pane_model : nil, same_agent ? pane_switch : nil)
      queued = queue_with_base_branch(client, task:, workspace:, base_branch:, driver:, model:, default:)
      return unless queued

      capacity = queued.fetch("capacity", {})
      agent = [ queued["driver"], queued["model"] ].compact.join(", ")
      say ""
      say bold("Queued #{queued.fetch('runId')} from #{queued.fetch('baseBranch', base_branch || default)}#{" (#{agent})" unless agent.empty?}.")
      behind = queued.fetch("queuedBehind", 0)
      say "#{capacity['inFlight']} of #{capacity['limit']} sessions in use#{behind.positive? ? ", #{behind} queued ahead of it" : ''}. " \
        "Its herdr workspace opens when it starts."
      pause
    end

    # A mistyped base branch is the one queue error worth another try: asking
    # again keeps the task the operator just wrote.
    def queue_with_base_branch(client, task:, workspace:, base_branch:, driver:, model:, default:)
      loop do
        return client.queue(task:, workspace: workspace.fetch("name"), base_branch:, driver:, model:)
      rescue PaneyardSandbox::McpClient::ToolError => error
        raise unless error.payload["error"] == "base_branch_invalid"

        say ""
        say error.payload["message"]
        base_branch = ask_base_branch(default, workspace.fetch("defaultBaseBranch"), again: true)
        if base_branch == :cancel
          say "Nothing queued."
          return pause
        end
      end
    end

    # The branch this pane is on, since that is what the operator is working
    # on (the workspace's default only on a detached HEAD), unless they name
    # another. Always sent explicitly: the server's own fallback is the
    # workspace default, not this pane's branch.
    def ask_base_branch(default, workspace_default, again: false)
      hint = default == workspace_default ? "" : "; workspace default: #{workspace_default}"
      hint += "; q cancels" if again
      answer = ask("Base branch (Enter for #{default}#{hint}): ")
      return :cancel if again && (answer.nil? || answer == "q")

      answer.nil? || answer.empty? ? default : answer
    end

    def runs_ui
      client = connect!
      loop do
        entries = run_entries(client)
        heading "Paneyard jobs"
        if entries.empty?
          say "No jobs yet. Use \"Hand off a task\" in a repository's pane."
        else
          entries.each_with_index { |(workspace, run), index| say run_line(index + 1, workspace, run) }
        end
        say ""
        choice = ask("Number for a job, Enter to refresh, q to quit: ")
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
        say "This herdr workspace is not a Paneyard job's."
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
      show_skill_command
      pause
    end

    # skills/paneyard teaches an agent to queue well. Linked rather than
    # copied, so it follows the plugin's own updates; setup prints the command
    # rather than writing into the agent's own configuration.
    def show_skill_command
      say ""
      say "To teach Claude Code how to hand off jobs well, link Paneyard's skill:"
      say "  mkdir -p ~/.claude/skills && ln -sfn #{File.join(paths.app_root, 'skills', 'paneyard')} ~/.claude/skills/paneyard"
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
      show_skill_command
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
        say dim("#{workspace.fetch('name')} · #{[ run['driver'], run['model'] ].compact.join(' ')} · #{run['branch'] || 'no branch yet'} from #{run['baseBranch']}")
        say dim("Follow-up of #{run['parentRunId']}") if run["parentRunId"]
        say dim("Follow-ups: #{run['followUpRunIds'].join(', ')}") if Array(run["followUpRunIds"]).any?
        say dim("After: #{run['after'].join(', ')}") if Array(run["after"]).any?
        say run.dig("dependencies", "reason") if run.dig("dependencies", "reason")
        say dim(run["worktree"]) if run["worktree"]
        say "Launch error: #{run['launchError']}" if run["launchError"]
        show_report(run)
        say ""
        options = []
        options << "f to go to its herdr workspace" if live && session["herdrWorkspace"]
        options << "c to close its session" if live
        options << "o to reopen its session" if run["reopenable"]
        waiting = %w[waiting blocked].include?(run.dig("dependencies", "state"))
        options << "s to start it without waiting" if waiting
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
        when "o"
          next unless run["reopenable"]

          reopen!(client, workspace, run)
          pause
          return :quit
        when "s"
          next unless waiting

          release!(client, workspace, run)
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

    def reopen!(client, workspace, run)
      say ""
      say "Reopening queues the run again for a new session on #{run['branch'] || 'a new branch'}, resuming its agent's"
      say "conversation if it can, and otherwise starting fresh with its task and newest report."
      return say("Left it closed.") unless ask("Reopen #{run.fetch('runId')}'s session? [y/N] ")&.downcase == "y"

      reopened = client.reopen(run.fetch("runId"), workspace: workspace.fetch("name"))
      worktree = { "kept" => "in its kept worktree", "recreated" => "in a worktree made again from its branch" }
      say bold("Reopened. Run #{reopened.fetch('status')}#{", #{worktree[reopened['worktree']]}" if worktree[reopened['worktree']]}.")
      capacity = reopened.fetch("capacity", {})
      behind = reopened.fetch("queuedBehind", 0)
      say "#{capacity['inFlight']} of #{capacity['limit']} sessions in use#{behind.positive? ? ", #{behind} queued ahead of it" : ''}. " \
        "Its herdr workspace opens when it starts."
    rescue PaneyardSandbox::McpClient::ToolError => error
      say error.payload["message"] || error.message
    end

    def release!(client, workspace, run)
      say ""
      say "It then starts when a slot frees, from #{run['baseBranch']} as it is, without #{run['after'].join(', ')}'s work."
      return say("Left it waiting.") unless ask("Start #{run.fetch('runId')} without waiting? [y/N] ")&.downcase == "y"

      client.release(run.fetch("runId"), workspace: workspace.fetch("name"))
      say bold("Released. It starts when a slot frees.")
    rescue PaneyardSandbox::McpClient::ToolError => error
      say error.payload["message"] || error.message
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
        .sort_by { |_workspace, run| run.fetch("runId") }.reverse.first(40)
    end

    # A follow-up -- a run started from another run's branch -- shows its
    # parent's short id after its own: `22da ↳7efb`.
    def run_line(number, workspace, run)
      width = IO.console&.winsize&.last || 100
      session = run["session"] || {}
      waiting = run.dig("dependencies", "state")
      state =
        if session["live"] && session["agentStatus"] then "#{run['status']}/#{session['agentStatus']}"
        elsif waiting && waiting != "met" then "#{run['status']}/#{waiting}"
        else run["status"]
        end
      parent = run["parentRunId"] ? "↳#{run['parentRunId'][-4..]}" : ""
      line = format("%3d  %-4s %-5s  %-18s  %-8s  %-14s  ", number, run.fetch("runId")[-4..], parent, state, run["driver"],
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
      # Keep an anchor immediately above the composer. Repainting from it is
      # what makes deletion work across both explicit newlines and terminal
      # line wrapping; cursor-relative "backspace, space, backspace" does not.
      @out.print("\e[s")
      repaint_task(task)
      @out.flush
      @in.raw do
        loop do
          key = @in.getch
          case key
          when "\r"
            # Raw mode: a bare newline would leave the next prompt mid-line.
            @out.print("\r\n")
            break
          when "\n"
            task << "\n"
            repaint_task(task)
          when "\u0003"
            raise Interrupt
          when "\u007f", "\b"
            next if task.empty?

            task.chop!
            repaint_task(task)
          when "\e"
            sequence = read_escape_sequence
            if sequence == "[13;2u"
              task << "\n"
              repaint_task(task)
            end
          else
            task << key
            repaint_task(task)
          end
          @out.flush
        end
      end
      task.strip
    end

    def repaint_task(task)
      @out.print("\e[u\e[J")
      task.split("\n", -1).each_with_index do |line, index|
        @out.print("\r\n") if index.positive?
        @out.print(accent("› "), line)
      end
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

    # Enter keeps the agent the operator is using in this pane; with none
    # there, the server's default (claude).
    def ask_driver(pane_driver)
      loop do
        answer = ask("Agent: #{DRIVERS.join(', ')} (Enter for #{pane_driver ? "#{pane_driver}, this pane's" : 'claude'}): ")
        return pane_driver if answer.nil? || answer.empty?
        return answer if DRIVERS.include?(answer)

        say "Not one of #{DRIVERS.join(', ')}."
      end
    end

    # Enter keeps this pane's model when the run uses this pane's agent, and
    # otherwise leaves it to the server (the driver's default model). A number
    # picks from what the CLI offers; anything else is taken as a model id.
    def ask_model(client, workspace, driver, pane_model, pane_switch = nil)
      listed = begin
        client.models(driver, workspace: workspace.fetch("name"))
      rescue Client::Error
        {}
      end
      models = Array(listed["models"])
      pane_model = switched_model(models, pane_switch) || pane_model
      choices = models.first(MODEL_CHOICES_SHOWN)
      choices.each_with_index { |choice, index| say dim(format("%3d  %s", index + 1, choice["label"] || choice["id"])) }
      default = if pane_model
        "#{pane_model}, this pane's"
      else
        listed["defaultModel"] ? "#{listed['defaultModel']}, the default" : "#{driver}'s own default"
      end
      loop do
        answer = ask("Model (Enter for #{default}#{'; or a number' if choices.any?}; or a model id): ")
        return pane_model if answer.nil? || answer.empty?
        return answer unless answer.match?(/\A\d+\z/)

        choice = choices[answer.to_i - 1] if answer.to_i.positive?
        return choice["id"] if choice

        say "No model #{answer}."
      end
    end

    # A /model switch is logged by display name ("Opus 5"); the id is the one
    # whose label is that name (ModelDiscovery labels are "Name — id").
    def switched_model(models, name)
      return unless name

      models.find { |model| [ model["id"], model["label"], model["label"].to_s.split(" — ").first ].include?(name) }&.fetch("id")
    end

    # The agent herdr sees in the focused pane and the model it is on: what
    # the operator is working with there, so what a run queued from it
    # defaults to. [driver, model id, display name of a /model switch not
    # yet answered on].
    def pane_agent
      driver = context["focused_pane_agent"]
      return [ nil, nil, nil ] unless DRIVERS.include?(driver)

      logged = SessionModel.for(driver, pane_session_id(driver), env: @env)
      [ driver, logged&.id || command_line_model(driver), logged&.switched_to ]
    end

    # The CLI's own session id, which herdr reports for the pane's agent.
    def pane_session_id(driver)
      pane = context["focused_pane_id"]
      return unless pane.is_a?(String) && !pane.empty?

      session = herdr_json("agent", "get", pane)&.dig("result", "agent", "agent_session")
      session["value"] if session.is_a?(Hash) && session["agent"] == driver && session["kind"] == "id"
    end

    def command_line_model(driver)
      pane = context["focused_pane_id"]
      return unless pane.is_a?(String) && !pane.empty?

      info = herdr_json("pane", "process-info", "--pane", pane)&.dig("result", "process_info") || {}
      Array(info["foreground_processes"]).each do |process|
        argv = Array(process["argv"]).map(&:to_s)
        # `claude ...`, or an interpreter running it (`node .../codex ...`).
        start = argv.first(2).index { |arg| File.basename(arg) == driver }
        return model_flag(driver, argv.drop(start + 1)) if start
      end
      nil
    end

    def model_flag(driver, args)
      args.each_with_index do |arg, index|
        MODEL_FLAGS.fetch(driver).each do |flag|
          return args[index + 1] if arg == flag
          return arg.delete_prefix("#{flag}=") if arg.start_with?("#{flag}=")
        end
        if driver == "codex" && %w[-c --config].include?(arg) && args[index + 1].to_s.start_with?("model=")
          return args[index + 1].delete_prefix("model=").delete(%("'))
        end
      end
      nil
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
        "Port #{result.previous_port} was taken. Re-register MCP: #{result.url}/mcp/admin (action: paneyard.setup)")
    end

    def notify(title, body)
      herdr("notification", "show", title, "--body", body)
    end

    def herdr(*args)
      system(herdr_bin, *args, out: File::NULL, err: File::NULL)
    rescue SystemCallError
      false
    end

    # A read-only herdr CLI call's JSON, or nil.
    def herdr_json(*args)
      output, status = Open3.capture2(herdr_bin, *args, err: File::NULL)
      status.success? ? JSON.parse(output) : nil
    rescue SystemCallError, JSON::ParserError
      nil
    end

    def herdr_bin = @env["HERDR_BIN_PATH"].to_s.empty? ? "herdr" : @env["HERDR_BIN_PATH"]

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
    rescue StandardError => error
      say ""
      say "Paneyard hit an unexpected error: #{error.class}: #{error.message}"
      say dim(error.backtrace&.first.to_s)
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

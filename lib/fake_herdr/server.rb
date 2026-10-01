require "json"
require "open3"
require "socket"
require "fileutils"

module FakeHerdr
  # A stand-in for the operator's herdr server, speaking the same
  # newline-delimited JSON-RPC over a Unix socket that Orchestrator::Runner::Herdr
  # does (one request line in, one response line out, per connection). The
  # response shapes are the ones Orchestrator::Runner::Herdr's header documents as
  # confirmed live -- root_pane on workspace.create, the "read" nesting on
  # pane.read, "process_info", "agent target ... not found" -- so the real
  # client and RunSessionRunner run unmodified against it.
  #
  # agent.start spawns a real process (script/fake_agent by default) in its
  # own process group, so the pid Rails records, kills and probes is real:
  # RunSessionRunner.kill_process and process_alive? and
  # RunSessionReconcileJob's "the CLI exited" path behave exactly as they do
  # against herdr. The agent reports its status back over its stdout and
  # receives prompts on its stdin (see FakeHerdr::Agent).
  #
  # worktree.create/open/remove make and remove real git worktrees, as herdr
  # does, in a directory the fake chooses the way herdr's own config would:
  # <repository's parent>/.herdr-worktrees/<repository>/<branch>, so a
  # sandbox's worktrees stay inside the sandbox.
  #
  # Nothing here runs a model or touches the operator's real herdr.
  class Server
    SHELL_PID_BASE = 4_000_000
    # A real pane's shell starts from the operator's login environment, not
    # from whatever process runs herdr, so the Bundler activation of this
    # server's own parent (a spec run, bin/sandbox) must not leak into it.
    FRESH_SHELL_ENV = %w[RUBYOPT BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLER_SETUP BUNDLER_VERSION].to_h { |key| [ key, nil ] }.freeze

    attr_reader :socket_path

    def initialize(socket_path:, agent_command: nil, agent_env: {}, log: nil)
      @socket_path = socket_path
      @agent_command = agent_command || [ RbConfig.ruby, File.expand_path("../../script/fake_agent", __dir__) ]
      @agent_env = agent_env
      @log = log
      @mutex = Mutex.new
      @requests = []
      @workspaces = {}
      @panes = {}
      @next_workspace = 0
      @threads = []
    end

    def start
      FileUtils.rm_f(socket_path)
      @server = UNIXServer.new(socket_path)
      @accept_thread = Thread.new { accept_loop }
      self
    end

    def stop
      @stopping = true
      @mutex.synchronize { @panes.each_value { |pane| kill_agent(pane) } }
      @server&.close
      @accept_thread&.join(2)
      FileUtils.rm_f(socket_path)
    end

    # Every request received, oldest first, as [method, params].
    def requests
      @mutex.synchronize { @requests.dup }
    end

    def requests_for(method)
      requests.select { |name, _| name == method }.map(&:last)
    end

    def pane(pane_id)
      @mutex.synchronize { @panes[pane_id]&.dup }
    end

    def workspace_ids
      @mutex.synchronize { @workspaces.keys }
    end

    # The operator closing a workspace by hand, from outside Rails.
    def close_workspace!(workspace_id)
      handle("workspace.close", "workspace_id" => workspace_id)
    end

    # Handles one decoded request and returns the response envelope. Public
    # so specs can drive the fake without a socket.
    def call(request)
      id = request["id"]
      method = request["method"]
      params = request["params"] || {}
      @mutex.synchronize { @requests << [ method, params ] }
      log("-> #{method} #{params.except('env', 'text').to_json}")
      { "id" => id, "result" => handle(method, params) }
    rescue MethodError => error
      { "id" => id, "error" => { "code" => error.code, "message" => error.message } }
    end

    class MethodError < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    private

    def accept_loop
      loop do
        client = @server.accept
        @threads << Thread.new(client) { |connection| serve(connection) }
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def serve(connection)
      line = connection.gets
      return if line.nil?

      response = begin
        call(JSON.parse(line))
      rescue JSON::ParserError => error
        { "id" => nil, "error" => { "code" => "parse_error", "message" => error.message } }
      end
      connection.write("#{JSON.generate(response)}\n")
    rescue IOError, Errno::EPIPE, Errno::ECONNRESET
      nil
    ensure
      connection.close rescue nil
    end

    def handle(method, params)
      @mutex.synchronize do
        case method
        when "workspace.create" then workspace_create(params)
        when "workspace.get" then { "workspace" => workspace!(params["workspace_id"]).except(:panes) }
        when "workspace.focus" then workspace!(params["workspace_id"]) && {}
        when "workspace.close" then workspace_close(params["workspace_id"])
        when "tab.create" then tab_create(params)
        when "tab.rename" then {}
        when "tab.close" then tab_close(params["tab_id"])
        when "pane.list" then { "panes" => panes_in(workspace!(params["workspace_id"])["workspace_id"]) }
        when "worktree.create" then worktree_create(params)
        when "worktree.open" then worktree_open(params)
        when "worktree.remove" then worktree_remove(params)
        when "worktree.list" then { "worktrees" => git_worktrees(repository_root!(params["cwd"])) }
        when "pane.split" then { "pane" => new_pane(pane!(params["target_pane_id"])[:workspace_id], params) }
        when "pane.rename" then pane_rename(params)
        when "pane.get" then { "pane" => public_pane(pane!(params["pane_id"])) }
        when "pane.send_input" then pane_send_input(params)
        when "pane.process_info" then { "process_info" => process_info(pane!(params["pane_id"])) }
        when "pane.read" then pane_read(params)
        when "agent.start" then agent_start(params)
        when "agent.get" then { "agent" => agent_info(agent_pane!(params["target"])) }
        when "agent.prompt" then agent_prompt(params)
        when "agent.send_keys" then agent_send_keys(params)
        when "notification.show" then {}
        else raise MethodError.new("method_not_found", "unknown method #{method}")
        end
      end
    end

    def workspace_create(params)
      @next_workspace += 1
      workspace_id = "w#{@next_workspace}"
      @workspaces[workspace_id] = { "workspace_id" => workspace_id, "label" => params["label"], tabs: 0, panes: 0 }
      root_pane = new_pane(workspace_id, params, new_tab: true)
      { "workspace" => { "workspace_id" => workspace_id, "label" => params["label"] }, "root_pane" => root_pane }
    end

    # A linked worktree of the repository at cwd, from `base` (or HEAD) on a
    # new branch, or on `branch` as is when it already exists; opened as a
    # workspace, like herdr.
    def worktree_create(params)
      repository = repository_root!(params["cwd"])
      branch = params["branch"].to_s
      path = File.join(File.dirname(repository), ".herdr-worktrees", File.basename(repository), branch.tr("/", "-"))
      raise MethodError.new("worktree_create_failed", "fatal: '#{path}' already exists") if File.exist?(path)

      FileUtils.mkdir_p(File.dirname(path))
      args = if git_ok?(repository, "rev-parse", "--verify", "--quiet", "refs/heads/#{branch}")
        [ "worktree", "add", path, branch ]
      else
        base = params["base"].to_s
        [ "worktree", "add", "-b", branch, path, base.empty? ? "HEAD" : base ]
      end
      git!(repository, *args, code: "worktree_create_failed")
      opened = open_worktree_workspace(repository, path, params["label"])
      opened.merge("worktree" => worktree_record(path, branch, opened.dig("workspace", "workspace_id")))
    end

    def worktree_open(params)
      repository = repository_root!(params["cwd"])
      path = params["path"]
      entry = git_worktrees(repository).find { |worktree| same_path?(worktree["path"], path) }
      raise MethodError.new("worktree_not_found", "no worktree at #{path}") unless entry

      open_id = @workspaces.find { |_, workspace| workspace[:path] && same_path?(workspace[:path], path) }&.first
      if open_id
        return { "workspace" => @workspaces[open_id].slice("workspace_id", "label"), "already_open" => true,
                 "worktree" => entry.merge("open_workspace_id" => open_id) }
      end

      opened = open_worktree_workspace(repository, path, params["label"])
      opened.merge("already_open" => false, "worktree" => entry.merge("open_workspace_id" => opened.dig("workspace", "workspace_id")))
    end

    # Like herdr: only an open, linked worktree's workspace; refuses a dirty
    # one unless forced; closes the workspace; keeps the branch.
    def worktree_remove(params)
      workspace = workspace!(params["workspace_id"])
      path = workspace[:path]
      raise MethodError.new("not_linked_worktree", "workspace is not a linked worktree checkout") unless path && workspace[:linked]

      args = [ "worktree", "remove", *("--force" if params["force"]), path ]
      _out, error, status = Open3.capture3("git", "-C", workspace[:repository], *args)
      unless status.success?
        code = error.include?("modified or untracked") ? "dirty_worktree_requires_force" : "worktree_remove_failed"
        raise MethodError.new(code, error.strip)
      end
      workspace_close(params["workspace_id"])
      { "type" => "worktree_removed", "workspace_id" => params["workspace_id"], "path" => path, "forced" => !!params["force"] }
    end

    def open_worktree_workspace(repository, path, label)
      created = workspace_create("cwd" => path, "label" => label)
      workspace_id = created.dig("workspace", "workspace_id")
      @workspaces[workspace_id].merge!(path:, repository:, linked: true)
      created.merge("tab" => { "tab_id" => created.dig("root_pane", "tab_id") })
    end

    def worktree_record(path, branch, workspace_id)
      { "path" => File.realpath(path), "branch" => branch, "is_linked_worktree" => true, "open_workspace_id" => workspace_id }
    end

    def git_worktrees(repository)
      git!(repository, "worktree", "list", "--porcelain").split("\n\n").map do |block|
        fields = block.lines.to_h { |line| line.chomp.split(" ", 2) }
        { "path" => fields["worktree"], "branch" => fields["branch"].to_s.delete_prefix("refs/heads/") }
      end
    end

    def repository_root!(cwd)
      raise MethodError.new("invalid_params", "cwd must be absolute") unless cwd.to_s.start_with?("/")

      git!(cwd, "rev-parse", "--show-toplevel", code: "not_a_repository").strip
    end

    def git_ok?(dir, *args)
      _out, _err, status = Open3.capture3("git", "-C", dir, *args)
      status.success?
    end

    def git!(dir, *args, code: "git_failed")
      out, error, status = Open3.capture3("git", "-C", dir.to_s, *args)
      raise MethodError.new(code, error.strip.empty? ? out.strip : error.strip) unless status.success?

      out
    end

    def same_path?(one, other)
      File.realpath(one.to_s) == File.realpath(other.to_s)
    rescue SystemCallError
      File.expand_path(one.to_s) == File.expand_path(other.to_s)
    end

    def panes_in(workspace_id)
      @panes.values.select { |pane| pane[:workspace_id] == workspace_id }.map { |pane| public_pane(pane) }
    end

    def tab_close(tab_id)
      panes = @panes.select { |_, pane| pane[:tab_id] == tab_id }
      raise MethodError.new("tab_not_found", "tab #{tab_id} not found") if panes.empty?

      panes.each do |pane_id, pane|
        kill_agent(pane)
        @panes.delete(pane_id)
      end
      {}
    end

    def workspace_close(workspace_id)
      workspace!(workspace_id)
      @panes.select { |_, pane| pane[:workspace_id] == workspace_id }.each do |pane_id, pane|
        kill_agent(pane)
        @panes.delete(pane_id)
      end
      @workspaces.delete(workspace_id)
      {}
    end

    def tab_create(params)
      workspace!(params["workspace_id"])
      root_pane = new_pane(params["workspace_id"], params, new_tab: true)
      { "tab" => { "tab_id" => root_pane["tab_id"], "label" => params["label"] }, "root_pane" => root_pane }
    end

    def new_pane(workspace_id, params, new_tab: false)
      workspace = @workspaces.fetch(workspace_id)
      workspace[:tabs] += 1 if new_tab
      workspace[:panes] += 1
      pane_id = "#{workspace_id}:p#{workspace[:panes]}"
      pane = {
        pane_id:, workspace_id:, tab_id: "#{workspace_id}:t#{workspace[:tabs]}",
        cwd: params["cwd"], env: params["env"] || {}, label: nil,
        shell_pid: SHELL_PID_BASE + @panes.size + 1, input: [], transcript: +"", agent: nil
      }
      @panes[pane_id] = pane
      public_pane(pane)
    end

    def public_pane(pane)
      { "pane_id" => pane[:pane_id], "tab_id" => pane[:tab_id], "workspace_id" => pane[:workspace_id] }
    end

    def pane_rename(params)
      pane!(params["pane_id"])[:label] = params["label"]
      {}
    end

    def pane_send_input(params)
      pane = pane!(params["pane_id"])
      pane[:input] << { "text" => params["text"], "keys" => params["keys"] }
      pane[:transcript] << "$ #{params['text']}\n"
      {}
    end

    def pane_read(params)
      text = pane!(params["pane_id"])[:transcript]
      lines = params["lines"]
      text = text.lines.last(lines.to_i).join if lines
      { "type" => "pane_read", "read" => { "text" => text, "truncated" => false } }
    end

    def process_info(pane)
      agent = pane[:agent]
      if agent && agent[:alive]
        { "shell_pid" => pane[:shell_pid], "foreground_process_group_id" => agent[:pid],
          "foreground_processes" => [ { "pid" => agent[:pid], "name" => agent[:kind] } ] }
      else
        { "shell_pid" => pane[:shell_pid], "foreground_process_group_id" => pane[:shell_pid],
          "foreground_processes" => [ { "pid" => pane[:shell_pid], "name" => "zsh" } ] }
      end
    end

    # herdr refuses agent.start unless the pane sits at an idle shell.
    def agent_start(params)
      pane = pane!(params["pane_id"])
      if pane[:agent]&.fetch(:alive)
        raise MethodError.new("pane_busy", "pane #{pane[:pane_id]} is not an available shell")
      end

      pane[:transcript] << "$ #{params['kind']} #{Array(params['args']).join(' ')}\n"
      pane[:agent] = spawn_agent(pane, params)
      { "launch_pending" => true }
    end

    def spawn_agent(pane, params)
      stdin_reader, stdin_writer = IO.pipe
      stdout_reader, stdout_writer = IO.pipe
      env = FRESH_SHELL_ENV.merge(@agent_env).merge(pane[:env]).merge("FAKE_HERDR_PANE_ID" => pane[:pane_id])
      pid = Process.spawn(
        env, *@agent_command, *Array(params["args"]),
        chdir: pane[:cwd] || Dir.pwd, pgroup: true, in: stdin_reader, out: stdout_writer, err: stdout_writer
      )
      stdin_reader.close
      stdout_writer.close
      waiter = Process.detach(pid)
      agent = {
        pid:, kind: params["kind"], name: params["name"], stdin: stdin_writer, alive: true,
        detected: false, ready: false, status: "unknown", session: nil, waiter:
      }
      @threads << Thread.new { read_agent(pane, agent, stdout_reader) }
      agent
    end

    # The agent's stdout is its control channel: JSON lines update the status
    # herdr would detect from the screen; anything else is screen output.
    def read_agent(pane, agent, io)
      io.each_line do |line|
        message = begin
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end
        @mutex.synchronize do
          if message.is_a?(Hash) && message.key?("fake_herdr")
            update = message["fake_herdr"]
            agent[:detected] = true
            agent[:status] = update["status"] if update["status"]
            agent[:ready] = update["ready"] if update.key?("ready")
            agent[:session] = update["session"] if update["session"]
          else
            pane[:transcript] << line
          end
        end
      end
    rescue IOError
      nil
    ensure
      agent[:waiter].join
      @mutex.synchronize do
        agent[:alive] = false
        agent[:status] = "unknown"
        pane[:transcript] << "[fake agent exited]\n"
      end
      log("agent #{agent[:pid]} in #{pane[:pane_id]} exited")
    end

    # herdr names the agent only once it recognises the CLI's own process, so
    # a launch that runs something else (a shell error, a missing binary) is
    # never "detected". The fake agent's first control line stands in for
    # that recognition.
    def agent_info(pane)
      agent = pane[:agent]
      {
        "agent" => agent[:alive] && agent[:detected] ? agent[:kind] : nil,
        "interactive_ready" => agent[:alive] && agent[:ready],
        "agent_status" => agent[:status],
        "agent_session" => agent[:session] && { "agent" => agent[:kind], "kind" => "id", "value" => agent[:session] }
      }
    end

    def agent_prompt(params)
      pane = agent_pane!(params["target"])
      write_agent(pane, "type" => "prompt", "text" => params["text"])
      pane[:transcript] << "> #{params['text'].to_s.lines.first}"
      {}
    end

    def agent_send_keys(params)
      pane = agent_pane!(params["target"])
      write_agent(pane, "type" => "keys", "keys" => params["keys"])
      {}
    end

    def write_agent(pane, message)
      pane[:agent][:stdin].write("#{JSON.generate(message)}\n")
      pane[:agent][:stdin].flush
    rescue IOError, Errno::EPIPE
      raise MethodError.new("agent_not_running", "agent in pane #{pane[:pane_id]} is not running")
    end

    def kill_agent(pane)
      agent = pane[:agent]
      return unless agent && agent[:alive]

      Process.kill("TERM", -agent[:pid])
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def workspace!(workspace_id)
      @workspaces[workspace_id] || raise(MethodError.new("workspace_not_found", "workspace #{workspace_id} not found"))
    end

    def pane!(pane_id)
      @panes[pane_id] || raise(MethodError.new("pane_not_found", "pane #{pane_id} not found"))
    end

    def agent_pane!(pane_id)
      pane = pane!(pane_id)
      raise MethodError.new("agent_not_found", "agent target #{pane_id} not found") unless pane[:agent]

      pane
    end

    def log(message)
      @log&.puts("[fake_herdr] #{message}")
      @log&.flush
    end
  end
end

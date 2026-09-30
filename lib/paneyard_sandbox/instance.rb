require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "socket"
require_relative "../paneyard_sandbox"

module PaneyardSandbox
  # One isolated instance of this checkout's code: bin/production (so Puma and
  # Solid Queue, with this checkout's queue.yml and recurring.yml, exactly as
  # bin/service runs them) on a free port, against sqlite files under its own
  # storage dir, beside a fake herdr, with PANEYARD_SANDBOX=1 so
  # Orchestrator::Sandbox keeps it from reaching anything real.
  #
  # Its pids and port live in <root>/instance.json, so a later `bin/sandbox
  # stop` finds it. Nothing here reads or writes the production instance's
  # storage/, tmp/pids/production.pid, or port.
  class Instance
    class Error < StandardError; end

    STATE_FILE = "instance.json".freeze

    attr_reader :app_root, :root, :storage_dir, :log_path

    # fake_herdr: false runs against whatever herdr HERDR_SOCKET_PATH in `env`
    # names (bin/sandbox start --real-herdr) instead of starting a fake one.
    def initialize(app_root:, root:, storage_dir: nil, log_path: nil, env: {}, fake_herdr: true)
      @fake_herdr = fake_herdr
      @app_root = File.expand_path(app_root)
      @root = File.expand_path(root)
      @storage_dir = File.expand_path(storage_dir || File.join(@root, "storage"))
      @log_path = File.expand_path(log_path || File.join(@root, "instance.log"))
      @extra_env = env
      @state = read_state
    end

    def port
      @state["port"]
    end

    def url
      port && "http://127.0.0.1:#{port}"
    end

    def herdr_socket_path
      PaneyardSandbox.herdr_socket_path(root)
    end

    # What the running instance was started with (bin/sandbox status).
    def modes
      Array(@state["modes"])
    end

    def running?
      alive?(@state["pid"])
    end

    def start!(timeout: 120, modes: [])
      raise Error, "already running at #{url} (pid #{@state['pid']})" if running?

      # A dead instance's state file must not hand stop! pids that may since
      # have been reused.
      @state = {}
      FileUtils.mkdir_p([ root, storage_dir, File.dirname(log_path) ])
      File.write(log_path, "")
      port = free_port
      log = File.open(log_path, "a")
      start_fake_herdr!(log) if @fake_herdr

      pid = Process.spawn(
        # Loopback only: rails server in production otherwise listens on
        # 0.0.0.0, and /mcp/admin has no auth.
        env(port), File.join(app_root, "bin/production"), "-b", "127.0.0.1",
        chdir: app_root, pgroup: true, out: log, err: log, in: File::NULL
      )
      Process.detach(pid)
      @state = @state.merge("pid" => pid, "port" => port, "storage_dir" => storage_dir, "modes" => modes)
      File.write(state_path, JSON.pretty_generate(@state))

      wait_for("#{url}/up", timeout:) { raise_dead!(pid, "bin/production") || up? }
      self
    rescue StandardError
      stop!
      raise
    end

    def start_fake_herdr!(log)
      herdr_pid = Process.spawn(
        { "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil },
        RbConfig.ruby, File.join(app_root, "script/fake_herdr"), herdr_socket_path,
        chdir: app_root, pgroup: true, out: log, err: log, in: File::NULL
      )
      Process.detach(herdr_pid)
      @state["herdr_pid"] = herdr_pid
      wait_for("fake herdr socket", timeout: 10) { File.socket?(herdr_socket_path) || (raise_dead!(herdr_pid, "fake herdr") && false) }
    end

    def stop!(grace: 15)
      [ @state["pid"], @state["herdr_pid"] ].compact.each do |pid|
        signal(pid, "TERM")
        deadline = Time.now + grace
        sleep 0.1 while alive?(pid) && Time.now < deadline
        signal(pid, "KILL") if alive?(pid)
      end
      FileUtils.rm_f(state_path)
      FileUtils.rm_f(herdr_socket_path) if @fake_herdr
      @state = {}
    end

    def env(port = self.port)
      {
        "RAILS_ENV" => "production",
        "PORT" => port&.to_s,
        "PANEYARD_SANDBOX" => "1",
        "PANEYARD_SANDBOX_ROOT" => root,
        "PANEYARD_STORAGE_DIR" => storage_dir,
        "PANEYARD_RAILS_URL" => port && "http://127.0.0.1:#{port}",
        # Belt and braces: Orchestrator::Sandbox already ignores these.
        "HERDR_SOCKET_PATH" => herdr_socket_path,
        "TELEGRAM_BOT_TOKEN" => nil,
        "TELEGRAM_ALLOWED_USER_IDS" => nil,
        "GITHUB_APP_ID" => nil,
        "GITHUB_APP_PRIVATE_KEY" => nil,
        "PANEYARD_RUN_TOKEN" => nil,
        "PANEYARD_RUN_ID" => nil,
        "PIDFILE" => File.join(root, "puma.pid")
      }.merge(secret_env).merge(@extra_env)
    end

    # Runs a command (e.g. a rake task) against this instance's database and
    # environment. Returns [output, success].
    def run(*command)
      output = IO.popen(env, command, chdir: app_root, err: [ :child, :out ], &:read)
      [ output, $?.success? ]
    end

    def log_tail(lines = 60)
      File.exist?(log_path) ? File.readlines(log_path).last(lines).join : ""
    end

    def get(path, headers: {})
      uri = URI("#{url}#{path}")
      request = Net::HTTP::Get.new(uri)
      headers.each { |key, value| request[key] = value }
      Net::HTTP.start(uri.host, uri.port, read_timeout: 30) { |http| http.request(request) }
    end

    private

    # Production credentials need config/master.key, which a worktree does not
    # have (it is gitignored). Without one, give the instance a throwaway
    # secret_key_base; with one, leave it alone so credentials are exercised.
    def secret_env
      return {} if ENV["RAILS_MASTER_KEY"] || File.exist?(File.join(app_root, "config/master.key"))

      { "SECRET_KEY_BASE" => SecureRandom.hex(64) }
    end

    def up?
      get("/up").is_a?(Net::HTTPSuccess)
    rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, EOFError
      false
    end

    def raise_dead!(pid, what)
      return false if alive?(pid)

      raise Error, "#{what} exited during startup. Last lines of #{log_path}:\n#{log_tail}"
    end

    def wait_for(what, timeout:)
      deadline = Time.now + timeout
      until yield
        raise Error, "timed out after #{timeout}s waiting for #{what}. Last lines of #{log_path}:\n#{log_tail}" if Time.now > deadline

        sleep 0.2
      end
    end

    def free_port
      server = TCPServer.new("127.0.0.1", 0)
      server.addr[1]
    ensure
      server&.close
    end

    def signal(pid, name)
      Process.kill(name, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def alive?(pid)
      return false unless pid

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def state_path
      File.join(root, STATE_FILE)
    end

    def read_state
      File.exist?(state_path) ? JSON.parse(File.read(state_path)) : {}
    rescue JSON::ParserError
      {}
    end
  end
end

module PaneyardPlugin
  # Where the plugin keeps everything, from the directories herdr hands every
  # plugin command. HERDR_PLUGIN_ROOT is the managed source checkout, which a
  # reinstall replaces, so nothing durable goes there: state (databases,
  # logs, the generated secret, the port) lives in HERDR_PLUGIN_STATE_DIR and
  # the operator's settings in HERDR_PLUGIN_CONFIG_DIR/.env.
  #
  # Outside herdr (bin/herdr-plugin run from a shell) the same directories
  # are worked out the way herdr lays them out, so `bin/herdr-plugin status`
  # finds the daemon an action started.
  class Paths
    attr_reader :plugin_id, :app_root, :state_dir, :config_dir

    def initialize(env: ENV, app_root: APP_ROOT)
      @plugin_id = present(env["HERDR_PLUGIN_ID"]) || DEFAULT_ID
      @app_root = File.expand_path(present(env["HERDR_PLUGIN_ROOT"]) || app_root)
      home = present(env["HOME"]) || Dir.home
      state_home = present(env["XDG_STATE_HOME"]) || File.join(home, ".local", "state")
      config_home = present(env["XDG_CONFIG_HOME"]) || File.join(home, ".config")
      @state_dir = File.expand_path(present(env["HERDR_PLUGIN_STATE_DIR"]) || File.join(state_home, "herdr", "plugins", plugin_id))
      @config_dir = File.expand_path(present(env["HERDR_PLUGIN_CONFIG_DIR"]) || File.join(config_home, "herdr", "plugins", "config", plugin_id))
    end

    def env_file = File.join(config_dir, ".env")
    def storage_dir = File.join(state_dir, "storage")
    def runtime_dir = File.join(state_dir, "run_sessions")
    def log_dir = File.join(state_dir, "log")
    def log_file = File.join(log_dir, "paneyard.log")
    def daemon_file = File.join(state_dir, "daemon.json")
    def lock_file = File.join(state_dir, "daemon.lock")
    def port_file = File.join(state_dir, "port")
    def url_file = File.join(state_dir, "url")
    def secret_file = File.join(state_dir, "secret_key_base")
    def puma_pid_file = File.join(state_dir, "puma.pid")
    def manifest_file = File.join(app_root, "herdr-plugin.toml")

    # The same directories, for the runner-only process (bin/runner) the
    # plugin runs in remote mode beside nothing else: its own pid, port, log
    # and state files, so it never mistakes the orchestrator daemon's for its
    # own (a machine switched from local to remote mode may still have both).
    def runner = RunnerPaths.new(self)

    private

    def present(value)
      value.nil? || value.strip.empty? ? nil : value
    end
  end

  class RunnerPaths
    def initialize(paths)
      @paths = paths
    end

    def plugin_id = @paths.plugin_id
    def app_root = @paths.app_root
    def state_dir = @paths.state_dir
    def config_dir = @paths.config_dir
    def env_file = @paths.env_file
    def manifest_file = @paths.manifest_file
    def log_dir = @paths.log_dir
    def runtime_dir = @paths.runtime_dir
    def secret_file = @paths.secret_file

    # Where Rails' (unused) database configuration points: never the
    # orchestrator daemon's storage.
    def storage_dir = File.join(state_dir, "runner")
    def log_file = File.join(log_dir, "runner.log")
    def daemon_file = File.join(state_dir, "runner.json")
    def lock_file = File.join(state_dir, "runner.lock")
    def port_file = File.join(state_dir, "runner_port")
    def url_file = File.join(state_dir, "runner_url")
    def puma_pid_file = File.join(state_dir, "runner_puma.pid")
    # What was last registered with the orchestrator (Cli#register_runner!).
    def registration_file = File.join(state_dir, "runner_registration.json")
  end
end

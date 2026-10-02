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

    private

    def present(value)
      value.nil? || value.strip.empty? ? nil : value
    end
  end
end

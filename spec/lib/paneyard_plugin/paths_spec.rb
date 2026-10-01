require "spec_helper"
require_relative "../../../lib/paneyard_plugin"

RSpec.describe PaneyardPlugin::Paths do
  it "keeps state and config where herdr says" do
    paths = described_class.new(env: {
      "HERDR_PLUGIN_ID" => "paneyard", "HERDR_PLUGIN_ROOT" => "/plugins/paneyard",
      "HERDR_PLUGIN_STATE_DIR" => "/state/paneyard", "HERDR_PLUGIN_CONFIG_DIR" => "/config/paneyard"
    })

    expect(paths).to have_attributes(
      app_root: "/plugins/paneyard", state_dir: "/state/paneyard", config_dir: "/config/paneyard",
      env_file: "/config/paneyard/.env", storage_dir: "/state/paneyard/storage",
      runtime_dir: "/state/paneyard/run_sessions", log_file: "/state/paneyard/log/paneyard.log",
      secret_file: "/state/paneyard/secret_key_base", puma_pid_file: "/state/paneyard/puma.pid",
      manifest_file: "/plugins/paneyard/herdr-plugin.toml"
    )
  end

  it "works the same directories out the way herdr lays them out when run outside herdr" do
    paths = described_class.new(env: { "HOME" => "/home/op" }, app_root: "/src/paneyard")

    expect(paths).to have_attributes(
      plugin_id: "paneyard", app_root: "/src/paneyard",
      state_dir: "/home/op/.local/state/herdr/plugins/paneyard",
      config_dir: "/home/op/.config/herdr/plugins/config/paneyard"
    )
  end

  it "follows XDG overrides" do
    paths = described_class.new(env: { "HOME" => "/home/op", "XDG_STATE_HOME" => "/xs", "XDG_CONFIG_HOME" => "/xc", "HERDR_PLUGIN_ID" => "py" })

    expect(paths).to have_attributes(state_dir: "/xs/herdr/plugins/py", config_dir: "/xc/herdr/plugins/config/py")
  end
end

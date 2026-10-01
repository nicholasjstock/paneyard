# Paneyard as a herdr plugin (herdr-plugin.toml, bin/herdr-plugin): the
# daemon that runs this checkout's bin/production with its state in the
# plugin's state directory, and the small terminal client herdr's actions and
# popups drive it through. docs/herdr-plugin-plan.md has the design.
#
# Plain Ruby on purpose, standard library only, like lib/paneyard_sandbox:
# bin/herdr-plugin runs it without Bundler or Rails, so an action answers at
# once when the daemon is already up. Rails' autoloader ignores it.
module PaneyardPlugin
  APP_ROOT = File.expand_path("..", __dir__)
  DEFAULT_ID = "paneyard".freeze

  class Error < StandardError; end
end

require_relative "paneyard_plugin/paths"
require_relative "paneyard_plugin/env_file"
require_relative "paneyard_plugin/secrets"
require_relative "paneyard_plugin/daemon"
require_relative "paneyard_plugin/client"
require_relative "paneyard_plugin/workspace_match"

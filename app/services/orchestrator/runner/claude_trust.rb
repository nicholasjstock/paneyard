require "fileutils"
require "json"

module Orchestrator
  module Runner
    # Claude's folder-trust gate defaults to exiting. Fresh worktrees no longer
    # inherit trust from the repository root, so mark Paneyard's new worktree
    # as trusted before starting Claude in it.
    module ClaudeTrust
      module_function

      def trust!(dir, config_path: self.config_path)
        dir = File.expand_path(dir.to_s)
        config = File.exist?(config_path) ? JSON.parse(File.read(config_path)) : {}
        return false if config.dig("projects", dir, "hasTrustDialogAccepted")

        (config["projects"] ||= {})[dir] = (config["projects"][dir] || {}).merge("hasTrustDialogAccepted" => true)
        FileUtils.mkdir_p(File.dirname(config_path))
        tmp = "#{config_path}.paneyard-#{Process.pid}.tmp"
        File.write(tmp, JSON.pretty_generate(config))
        File.rename(tmp, config_path)
        true
      end

      def config_path
        File.join(ENV["CLAUDE_CONFIG_DIR"].presence || Dir.home, ".claude.json")
      end
    end
  end
end

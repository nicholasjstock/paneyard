require "json"

module Orchestrator
  module Runner
    # Claude's folder-trust gate defaults to exiting. Fresh worktrees no longer
    # inherit trust from the repository root, so mark Paneyard's new worktree
    # (or a lobby's checkout) as trusted before starting Claude in it.
    #
    # claude runs in the operator's login shell, whose CLAUDE_CONFIG_DIR this
    # process may not have: the herdr plugin's daemon was confirmed live to
    # run without it, marking ~/.claude.json while claude read
    # ~/.config/claude/.claude.json and sat at its trust prompt. So the folder
    # is marked in every config claude might read.
    module ClaudeTrust
      module_function

      # Whether any config had to be changed.
      def trust!(dir, config_paths: self.config_paths)
        dir = File.expand_path(dir.to_s)
        config_paths.map { |path| trust_in!(dir, path) }.any?
      end

      def trust_in!(dir, config_path)
        config = File.exist?(config_path) ? JSON.parse(File.read(config_path)) : {}
        return false if config.dig("projects", dir, "hasTrustDialogAccepted")

        (config["projects"] ||= {})[dir] = (config["projects"][dir] || {}).merge("hasTrustDialogAccepted" => true)
        ConfigFile.replace!(config_path, JSON.pretty_generate(config))
        true
      end

      # The config this process's environment names, created if need be, and
      # any other usual one that already exists.
      def config_paths
        primary = File.join(ENV["CLAUDE_CONFIG_DIR"].presence || Dir.home, ".claude.json")
        others = [ File.join(Dir.home, ".claude.json"), File.join(Dir.home, ".config", "claude", ".claude.json") ]
        [ primary, *others.select { |path| File.exist?(path) } ].map { |path| File.expand_path(path) }.uniq
      end
    end
  end
end

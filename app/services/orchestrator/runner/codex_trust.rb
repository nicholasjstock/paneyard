module Orchestrator
  module Runner
    # codex asks "Trust this folder?" the first time it starts in a folder it
    # has not been told to trust, and Paneyard can only answer that with a
    # blind Enter after a grace period (SessionLauncher's
    # dismiss_codex_trust_prompt!), which a slow start beats. So, as
    # ClaudeTrust does for claude, mark the folder trusted in codex's own
    # config before codex starts, and keep the Enter as the fallback.
    #
    # Confirmed live on codex 0.164.0: an appended
    # [projects."<dir>"] trust_level = "trusted" skips the prompt, for a
    # checkout and for a linked worktree marked by its own path. (A worktree
    # of a trusted repository is trusted already; a trusted parent directory
    # is not inherited.)
    #
    # The config is TOML, which Ruby cannot parse without a gem, so this edits
    # it as text, and only in the shape codex itself writes. A folder named
    # anywhere else in the file is left alone: a second table for it would be
    # a TOML error that stops codex from starting at all.
    module CodexTrust
      module_function

      # Whether any config had to be changed.
      def trust!(dir, config_paths: self.config_paths)
        dir = File.expand_path(dir.to_s)
        config_paths.map { |path| trust_in!(dir, path) }.any?
      end

      def trust_in!(dir, config_path)
        text = File.exist?(config_path) ? File.read(config_path) : ""
        lines = text.lines
        quoted = dir.to_json
        header = /\A\s*\[\s*projects\s*\.\s*#{Regexp.escape(quoted)}\s*\]\s*(#.*)?\z/
        start = lines.index { |line| line.match?(header) }
        return false if start.nil? && text.include?(quoted)

        trusted = %(trust_level = "trusted"\n)
        if start
          finish = (start + 1...lines.size).find { |i| lines[i].lstrip.start_with?("[") } || lines.size
          key = (start + 1...finish).find { |i| lines[i].match?(/\A\s*trust_level\s*=/) }
          return false if key && lines[key].match?(/\A\s*trust_level\s*=\s*"trusted"\s*(#.*)?\z/)

          key ? lines[key] = trusted : lines.insert(start + 1, trusted)
          text = lines.join
        else
          text += "\n" unless text.empty? || text.end_with?("\n")
          text += "\n[projects.#{quoted}]\n#{trusted}"
        end
        ConfigFile.replace!(config_path, text)
        true
      end

      # The config this process's environment names, created if need be, and
      # any other usual one that already exists -- the operator's shell may set
      # a CODEX_HOME this process does not have, as ClaudeTrust explains.
      def config_paths
        primary = File.join(ENV["CODEX_HOME"].presence || File.join(Dir.home, ".codex"), "config.toml")
        others = [ File.join(Dir.home, ".codex", "config.toml"), File.join(Dir.home, ".config", "codex", "config.toml") ]
        [ primary, *others.select { |path| File.exist?(path) } ].map { |path| File.expand_path(path) }.uniq
      end
    end
  end
end

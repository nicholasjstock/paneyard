module Orchestrator
  module TargetPreflight
    class Error < StandardError; end

    module_function

    # This boundary is intentionally source-agnostic. Repository commands run
    # inside the selected agent launcher's enforced sandbox; Rails checks only
    # that the workspace and launcher exist.
    def check!(run:, mode:, root: run.target_root)
      root = Pathname(root)
      raise Error, "Target workspace does not exist: #{root}" unless root.directory?

      require_command!(run.launcher_variant)
      true
    end

    def require_command!(command)
      return if executable_on_path?(command)

      raise Error, "Required agent launcher is unavailable: #{command}"
    end

    def executable_on_path?(command)
      return File.executable?(command) if command.include?(File::SEPARATOR)

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
        File.file?(File.join(directory, command)) && File.executable?(File.join(directory, command))
      end
    end
  end
end

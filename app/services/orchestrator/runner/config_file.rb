require "fileutils"

module Orchestrator
  module Runner
    # Replaces an agent CLI's own config file (ClaudeTrust, CodexTrust) in one
    # rename, so the CLI never reads it half written, keeping its mode: these
    # files can hold credentials, and some are kept 0600.
    module ConfigFile
      module_function

      def replace!(path, content)
        FileUtils.mkdir_p(File.dirname(path))
        tmp = "#{path}.paneyard-#{Process.pid}.tmp"
        File.write(tmp, content)
        File.chmod(File.stat(path).mode & 0o7777, tmp) if File.exist?(path)
        File.rename(tmp, path)
      end
    end
  end
end

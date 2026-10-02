require "fileutils"
require "securerandom"

module PaneyardPlugin
  # Production needs a secret_key_base, and a fresh install has neither a
  # config/master.key nor credentials (both are gitignored). The plugin makes
  # one the first time and keeps it in its state directory, readable by the
  # operator only, so `bin/rails credentials:edit` is never part of setup.
  # It signs cookies; nothing is encrypted with it, so losing it only logs
  # the browser out of nothing (there are no accounts).
  module Secrets
    module_function

    def secret_key_base(path)
      existing = read(path)
      return existing if existing

      FileUtils.mkdir_p(File.dirname(path))
      begin
        # Exclusive create: two starts racing each other must end up agreeing.
        File.write(path, SecureRandom.hex(64), mode: "wx", perm: 0o600)
      rescue Errno::EEXIST
        nil
      end
      read(path) || raise(Error, "could not read the secret_key_base Paneyard just wrote to #{path}")
    end

    def read(path)
      return nil unless File.exist?(path)

      value = File.read(path).strip
      value.empty? ? nil : value
    end
  end
end

require "fileutils"
require "securerandom"

module PaneyardPlugin
  # Production needs a secret_key_base. Make one the first time and keep it
  # in the instance's state directory, readable by the operator only.
  # It signs cookies; nothing is encrypted with it, so losing it only logs
  # the browser out of nothing (there are no accounts).
  module Secrets
    module_function

    def secret_key_base(path)
      existing = read(path)
      return existing if existing

      FileUtils.mkdir_p(File.dirname(path))
      # Two starts racing each other must end up agreeing, and neither may
      # see the file before it is complete: an exclusive create alone makes
      # it empty first, and the loser could read that. Write it in full
      # beside it, then link it into place, which fails if it is there.
      staged = "#{path}.#{Process.pid}.#{SecureRandom.hex(4)}"
      begin
        File.write(staged, SecureRandom.hex(64), mode: "wx", perm: 0o600)
        File.link(staged, path)
      rescue Errno::EEXIST
        nil
      ensure
        FileUtils.rm_f(staged)
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

require "shellwords"

# TerminalSessionRunner spawns real "claude"/"codex" binaries under a pty --
# unlike FakeAgentHarness (spec/support/fake_agent_process.rb), which
# simulates the one-shot --print worker flow by parsing a run/scope out of
# the prompt, an interactive session has no such prompt to parse. This fake
# just echoes stdin back with a prefix, ignoring every CLI arg, so specs can
# assert the pty read/write/log-append plumbing works without a real CLI.
module FakeTerminalCliHarness
  ECHO_LOOP = <<~'RUBY'
    STDOUT.sync = true
    loop do
      line = STDIN.gets
      break if line.nil?
      print "echo:#{line}"
    end
  RUBY

  def with_fake_terminal_clis
    Dir.mktmpdir("fake-terminal-cli") do |dir|
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(bin_dir)

      %w[claude codex].each do |name|
        path = File.join(bin_dir, name)
        File.write(path, "#!/bin/sh\nexec ruby -e #{Shellwords.escape(ECHO_LOOP)}\n")
        FileUtils.chmod("+x", path)
      end

      original_path = ENV["PATH"]
      ENV["PATH"] = "#{bin_dir}:#{original_path}"
      yield
    ensure
      ENV["PATH"] = original_path
    end
  end
end

RSpec.configure do |config|
  config.include FakeTerminalCliHarness
end

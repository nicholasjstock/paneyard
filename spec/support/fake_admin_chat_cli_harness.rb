# Orchestrator::WorkspaceAdminChatDriver's providers spawn real "claude"/
# "codex" binaries non-interactively (no pty, unlike
# spec/support/fake_terminal_cli_harness.rb's echo loop) and parse their
# stdout line by line. This fake writes a real executable ruby script that
# prints exactly the JSONL lines a test wants, after an optional delay, then
# exits with a given status -- letting specs exercise malformed-output,
# non-zero-exit, hang/cancel, and argv-capture cases against the real
# Open3.popen3 + IO.select plumbing in ProcessStream, without a real CLI.
module FakeAdminChatCliHarness
  def with_fake_admin_chat_cli(name:, lines: [], stderr_lines: [], exit_status: 0, start_delay: 0, hang: false, capture_args_to: nil)
    Dir.mktmpdir("fake-#{name}-admin-chat-cli") do |dir|
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(bin_dir)
      path = File.join(bin_dir, name)
      File.write(path, fake_cli_script(lines:, stderr_lines:, exit_status:, start_delay:, hang:, capture_args_to:))
      FileUtils.chmod("+x", path)

      original_path = ENV["PATH"]
      ENV["PATH"] = "#{bin_dir}:#{original_path}"
      yield
    ensure
      ENV["PATH"] = original_path
    end
  end

  def fake_cli_script(lines:, stderr_lines:, exit_status:, start_delay:, hang:, capture_args_to:)
    <<~RUBY
      #!/usr/bin/env ruby
      require "json"
      STDOUT.sync = true
      STDERR.sync = true
      $stdin.close
      File.write(#{capture_args_to.to_s.inspect}, ARGV.to_json) unless #{capture_args_to.nil?}
      sleep(#{start_delay.to_f})
      #{lines.map { |line| "puts #{line.inspect}" }.join("\n")}
      #{stderr_lines.map { |line| "STDERR.puts #{line.inspect}" }.join("\n")}
      #{"loop { sleep 1 }" if hang}
      exit(#{exit_status.to_i})
    RUBY
  end
end

RSpec.configure do |config|
  config.include FakeAdminChatCliHarness
end

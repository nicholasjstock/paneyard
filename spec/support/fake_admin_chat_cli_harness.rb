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
    if hang
      # Use a shell script for the hang case so that SIGTERM reliably
      # terminates the process via signal (Ruby's default SIGTERM handler
      # calls exit(0), which prevents Process::Status#signaled? from
      # returning true that the provider's cancelled? check relies on).
      cap = capture_args_to ? capture_args_to.shellescape : nil
      <<~SH
        #!/bin/sh
        #{cap ? %{ruby -e "File.write(#{cap.dump}, ARGV.to_json)" -- "$@"} : ""}
        sleep #{start_delay.to_f}
        #{lines.map { |line| "echo #{line.shellescape}" }.join("\n")}
        #{stderr_lines.map { |line| "echo #{line.shellescape} >&2" }.join("\n")}
        exec tail -f /dev/null
      SH
    else
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
        exit(#{exit_status.to_i})
      RUBY
    end
  end
end

RSpec.configure do |config|
  config.include FakeAdminChatCliHarness
end

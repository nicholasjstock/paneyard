require "open3"

module Orchestrator
  module WorkspaceAdminChatDriver
    # Shared non-interactive process plumbing for the claude/codex providers:
    # spawns a detached process-group leader (Open3.popen3 with pgroup: true,
    # same shape as Orchestrator::RunCommandRunner's Process.spawn) and yields
    # each stdout line as it arrives.
    #
    # Cancellation is deliberately *not* an in-memory flag checked in this
    # loop -- WorkspaceAdminChatTurnJob can run in a different OS process
    # than the request that wants to cancel it (bin/dev runs Solid Queue as
    # a separate process from Puma unless SOLID_QUEUE_IN_PUMA is set, as
    # config/deploy.yml sets in production). on_spawn hands the caller the
    # real pid the moment it's known so it can persist it (see
    # Runner#perform_turn) -- cancellation is then just Process.kill by that
    # pid from *any* process (see .kill_process_group, called directly from
    # Runner#cancel_turn!), which works across processes for free since OS
    # signals aren't scoped to the sender's memory the way an in-process
    # registry would be. The read loop is a plain blocking read; a kill from
    # elsewhere ends it by closing the pipe, same as the process exiting on
    # its own.
    module ProcessStream
      module_function

      READ_CHUNK_BYTES = 8_192
      KILL_GRACE_PERIOD = 5

      def run(env:, args:, chdir:, on_spawn: nil)
        stdin, stdout, stderr, wait_thr = Open3.popen3(env, *args, chdir:, pgroup: true)
        stdin.close
        on_spawn&.call(wait_thr.pid)

        buffer = "".dup
        loop do
          begin
            buffer << stdout.readpartial(READ_CHUNK_BYTES)
          rescue EOFError
            break
          end

          while (newline_index = buffer.index("\n"))
            yield buffer.slice!(0..newline_index)
          end
        end
        yield buffer unless buffer.strip.empty?

        { status: wait_thr.value, stderr: read_remaining(stderr) }
      ensure
        [ stdin, stdout, stderr ].each { |io| io.close if io && !io.closed? }
      end

      # Called from Runner#cancel_turn!, potentially in a different process
      # than the one running #run above -- see the module comment.
      def kill_process_group(pid)
        Process.kill("SIGTERM", -pid)
        deadline = Time.current + KILL_GRACE_PERIOD
        sleep(0.1) while Time.current < deadline && process_group_alive?(pid)
        Process.kill("SIGKILL", -pid) if process_group_alive?(pid)
      rescue Errno::ESRCH
        nil
      end

      def process_group_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      end

      def read_remaining(io)
        io.read.to_s
      rescue IOError, Errno::EIO
        ""
      end
    end
  end
end

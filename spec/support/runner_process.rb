require "net/http"
require "rbconfig"
require "securerandom"
require "socket"
require "tmpdir"

# A real runner-only process (bin/runner) for a spec: this checkout booted
# with PANEYARD_ROLE=runner on a free loopback port, beside its own herdr
# socket (a second FakeHerdr::Server, the "other machine's" herdr), with its
# own state directory and a throwaway HOME, so the claude trust it records
# for its worktrees never reaches the operator's ~/.claude.json.
#
#   process = RunnerProcess.new(herdr_socket: remote_herdr.socket_path).start
#   process.url  # => "http://127.0.0.1:41234"
#   process.stop
class RunnerProcess
  attr_reader :root, :port, :log_path

  def initialize(herdr_socket:, root: Dir.mktmpdir("runner-process"), port: nil)
    @herdr_socket = herdr_socket
    @root = root
    @port = port || free_port
    @log_path = File.join(root, "runner.log")
  end

  def url
    "http://127.0.0.1:#{port}"
  end

  def runtime_dir
    File.join(root, "state", "run_sessions")
  end

  def start(timeout: 60)
    ruby = RbConfig.ruby
    home = File.join(root, "home")
    FileUtils.mkdir_p(home)
    env = {
      "RAILS_ENV" => "production", "PORT" => port.to_s, "HOME" => home, "CLAUDE_CONFIG_DIR" => File.join(home, ".claude"),
      "CODEX_HOME" => File.join(home, ".codex"), "PANEYARD_STORAGE_DIR" => File.join(root, "state"),
      "PANEYARD_RUNTIME_DIR" => runtime_dir, "HERDR_SOCKET_PATH" => @herdr_socket, "PIDFILE" => File.join(root, "puma.pid"),
      "SECRET_KEY_BASE" => SecureRandom.hex(64), "PANEYARD_SANDBOX" => nil, "PANEYARD_SANDBOX_ROOT" => nil,
      "PANEYARD_ALLOWED_HOSTS" => nil, "PANEYARD_RAILS_URL" => nil,
      # The shebangs bin/runner runs must find this Ruby with HOME moved.
      "PATH" => [ File.dirname(ruby), ENV["PATH"] ].join(File::PATH_SEPARATOR)
    }
    @pid = Process.spawn(env, ruby, Rails.root.join("bin/runner").to_s, chdir: Rails.root.to_s, pgroup: true,
      out: [ log_path, "a" ], err: [ log_path, "a" ], in: File::NULL)
    deadline = Time.now + timeout
    until up?
      raise "bin/runner exited while starting:\n#{log}" unless alive?
      raise "bin/runner did not answer within #{timeout}s:\n#{log}" if Time.now > deadline

      sleep 0.1
    end
    self
  end

  def stop
    return unless @pid

    Process.kill("TERM", -@pid)
    Process.wait(@pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    @pid = nil
  end

  def log
    File.exist?(log_path) ? File.read(log_path) : ""
  end

  private

  def up?
    Net::HTTP.get_response(URI("#{url}/up"))["X-Paneyard-Role"] == "runner"
  rescue SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout
    false
  end

  def alive?
    Process.kill(0, @pid)
    true
  rescue Errno::ESRCH
    false
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end
end

require "net/http"
require "socket"
require "tmpdir"
require "timeout"

module RailsServerHarness
  def with_test_rails_server
    port = pick_free_port
    log_dir = Dir.mktmpdir("workflow-test-server")
    log_path = File.join(log_dir, "rails-server.log")
    pidfile = File.join(log_dir, "rails-server.pid")
    env = {
      "RAILS_ENV" => "test",
      "PORT" => port.to_s,
      "PIDFILE" => pidfile,
      "DISABLE_SPRING" => "1"
    }

    pid = Process.spawn(env, "bin/rails", "server", "-e", "test", "-p", port.to_s,
      chdir: Rails.root.to_s, out: [ log_path, "a" ], err: [ log_path, "a" ])
    Process.detach(pid)

    wait_for_server!(port: port, log_path: log_path)
    yield "http://127.0.0.1:#{port}", log_path
  ensure
    if pid
      begin
        Process.kill("TERM", pid)
      rescue Errno::ESRCH
        nil
      end
    end
  end

  private

  def pick_free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def wait_for_server!(port:, log_path:)
    Timeout.timeout(30) do
      loop do
        return if server_up?(port)

        sleep 0.1
      end
    end
  rescue Timeout::Error
    raise "Timed out waiting for test Rails server on port #{port}.\n#{File.read(log_path)}"
  end

  def server_up?(port)
    uri = URI("http://127.0.0.1:#{port}/up")
    response = Net::HTTP.get_response(uri)
    response.is_a?(Net::HTTPSuccess)
  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
    false
  end
end

RSpec.configure do |config|
  config.include RailsServerHarness
end

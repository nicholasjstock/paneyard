require "puma"
require "puma/server"

# Serves an Orchestrator::Runner::Endpoint over real HTTP on a free loopback
# port, in this process, for the duration of a block: what a runner-only
# process (bin/runner) serves, in front of whatever runner object the spec
# gives it -- usually a Runner::Local with Herdr stubbed, so the HTTP hop,
# the JSON and the error mapping are real and nothing else is.
#
#   with_runner_endpoint(runner: Orchestrator::Runner::Local.new(runtime_root: dir)) do |url|
#     Orchestrator::Runner::Remote.new(name: "mac", url:).ping
#   end
module RunnerEndpointServer
  def with_runner_endpoint(runner:, app: Orchestrator::Runner::Endpoint.new(runner:))
    rack = Rack::URLMap.new("/runner" => app)
    server = Puma::Server.new(rack, nil, min_threads: 0, max_threads: 4, log_writer: Puma::LogWriter.null)
    server.add_tcp_listener("127.0.0.1", 0)
    port = server.connected_ports.first
    server.run
    yield "http://127.0.0.1:#{port}"
  ensure
    server&.stop(true)
  end
end

RSpec.configure do |config|
  config.include RunnerEndpointServer
end

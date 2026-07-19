module Orchestrator
  class WorkerMcpEndpoint
    def initialize
      @transports = {}
      @mutex = Mutex.new
    end

    def call(env)
      token = env["HTTP_AUTHORIZATION"].to_s.delete_prefix("Bearer ")
      worker = Worker.authenticate_capability(token)
      return unauthorized unless worker

      transport_for(worker).call(env)
    end

    private

    def transport_for(worker)
      @mutex.synchronize do
        @transports.delete_if { |worker_id, _| !Worker.exists?(worker_id:, status: %w[launching running]) } if @transports.size >= 100
        @transports[worker.worker_id] ||= MCP::Server::Transports::StreamableHTTPTransport.new(
          WorkerMcpServer.build(server_context: { worker_id: worker.worker_id })
        )
      end
    end

    def unauthorized
      [ 401, { "content-type" => "application/json" }, [ '{"error":"invalid worker capability"}' ] ]
    end
  end
end

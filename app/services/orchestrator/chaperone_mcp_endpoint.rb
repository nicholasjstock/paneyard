module Orchestrator
  class ChaperoneMcpEndpoint
    def initialize
      @transports = {}
      @mutex = Mutex.new
    end

    def call(env)
      token = env["HTTP_AUTHORIZATION"].to_s.delete_prefix("Bearer ")
      review = ChaperoneReview.authenticate(token)
      return [ 401, { "content-type" => "application/json" }, [ '{"error":"invalid chaperone capability"}' ] ] unless review

      transport_for(review).call(env)
    end

    private

    def transport_for(review)
      @mutex.synchronize do
        @transports.delete_if { |review_id, _transport| review_id != review.id && !ChaperoneReview.where(id: review_id, status: %w[queued running]).exists? } if @transports.size >= 100
        @transports[review.id] ||= MCP::Server::Transports::StreamableHTTPTransport.new(
          ChaperoneMcpServer.build(server_context: { review_id: review.id })
        )
      end
    end
  end
end

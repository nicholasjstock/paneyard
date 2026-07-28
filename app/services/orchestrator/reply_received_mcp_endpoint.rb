module Orchestrator
  class ReplyReceivedMcpEndpoint
    def initialize
      @transports = {}
      @mutex = Mutex.new
    end

    def call(env)
      token = env["HTTP_AUTHORIZATION"].to_s.delete_prefix("Bearer ")
      review = ReplyReceivedReview.authenticate(token)
      return [ 401, { "content-type" => "application/json" }, [ '{"error":"invalid reply_received capability"}' ] ] unless review

      transport_for(review).call(env)
    end

    private

    def transport_for(review)
      @mutex.synchronize do
        @transports.delete_if { |review_id, _transport| review_id != review.id && !ReplyReceivedReview.where(id: review_id, status: %w[queued running]).exists? } if @transports.size >= 100
        @transports[review.id] ||= MCP::Server::Transports::StreamableHTTPTransport.new(
          ReplyReceivedMcpServer.build(server_context: { review_id: review.id })
        )
      end
    end
  end
end

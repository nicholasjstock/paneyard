require "json"
require "net/http"
require "uri"

module PaneyardSandbox
  # Just enough of an MCP Streamable HTTP client to call this app's own
  # /mcp/run and /mcp/admin tools the way a real CLI does: the initialize
  # handshake, the Mcp-Session-Id it hands back, then tools/call. Responses
  # may come back as JSON or as a one-event SSE stream; both are handled.
  class McpClient
    class Error < StandardError; end

    PROTOCOL_VERSION = "2025-06-18".freeze

    def initialize(url, token: nil, timeout: 30)
      @uri = URI(url)
      @token = token
      @timeout = timeout
      @next_id = 0
    end

    def tool_names
      initialize_session!
      rpc("tools/list").fetch("tools").map { |tool| tool.fetch("name") }
    end

    # Returns the tool's structuredContent (or its text content parsed as
    # JSON); raises when the tool reports an error.
    def call_tool(name, **arguments)
      initialize_session!
      result = rpc("tools/call", name:, arguments:)
      text = Array(result["content"]).filter_map { |part| part["text"] }.join("\n")
      raise Error, "#{name} failed: #{text}" if result["isError"]

      result["structuredContent"] || (JSON.parse(text) rescue { "text" => text })
    end

    private

    def initialize_session!
      return if @session_id

      rpc("initialize", protocolVersion: PROTOCOL_VERSION, capabilities: {},
        clientInfo: { name: "paneyard-sandbox", version: "1" })
      notify("notifications/initialized")
    end

    def rpc(method, **params)
      @next_id += 1
      response = post(jsonrpc: "2.0", id: @next_id, method:, params:)
      @session_id ||= response["mcp-session-id"]
      message = parse(response)
      raise Error, "#{method}: #{message['error']['message']}" if message["error"]

      message.fetch("result")
    end

    def notify(method)
      post(jsonrpc: "2.0", method:)
    end

    def post(body)
      request = Net::HTTP::Post.new(@uri)
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json, text/event-stream"
      request["Authorization"] = "Bearer #{@token}" if @token
      if @session_id
        request["Mcp-Session-Id"] = @session_id
        request["MCP-Protocol-Version"] = PROTOCOL_VERSION
      end
      request.body = JSON.generate(body)
      response = Net::HTTP.start(@uri.host, @uri.port, read_timeout: @timeout, open_timeout: @timeout) do |http|
        http.request(request)
      end
      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "POST #{@uri} (#{body[:method]}) returned #{response.code}: #{response.body.to_s[0, 500]}"
      end

      response
    end

    def parse(response)
      body = response.body.to_s
      if response["content-type"].to_s.include?("text/event-stream")
        data = body.lines.filter_map { |line| line.delete_prefix("data:").strip if line.start_with?("data:") }
        body = data.last.to_s
      end
      JSON.parse(body)
    rescue JSON::ParserError => error
      raise Error, "unparseable MCP response: #{error.message}: #{body[0, 500]}"
    end
  end
end

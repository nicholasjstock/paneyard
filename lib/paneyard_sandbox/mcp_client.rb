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

    # The server no longer knows this client's session: it restarted since the
    # handshake (sessions live in its memory), or reaped the session as idle.
    class SessionExpired < Error; end

    # A tool that ran and reported an error; `payload` is its JSON body
    # (`error`, `message`, and any details such as `problems`), when it had one.
    class ToolError < Error
      attr_reader :payload

      def initialize(message, payload = {})
        super(message)
        @payload = payload
      end
    end

    PROTOCOL_VERSION = "2025-06-18".freeze

    def initialize(url, token: nil, timeout: 30, client_name: "paneyard-sandbox")
      @uri = URI(url)
      @token = token
      @client_name = client_name
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
      raise ToolError.new("#{name} failed: #{text}", result["structuredContent"] || (JSON.parse(text) rescue {})) if result["isError"]

      result["structuredContent"] || (JSON.parse(text) rescue { "text" => text })
    end

    private

    def initialize_session!
      return if @session_id

      rpc("initialize", protocolVersion: PROTOCOL_VERSION, capabilities: {},
        clientInfo: { name: @client_name, version: "1" })
      notify("notifications/initialized")
    end

    # A session the server has forgotten is renewed once, transparently: a
    # popup left open across a Paneyard restart would otherwise fail on its
    # next call.
    def rpc(method, renew: true, **params)
      @next_id += 1
      response = begin
        post(jsonrpc: "2.0", id: @next_id, method:, params:)
      rescue SessionExpired
        raise unless renew && @session_id && method != "initialize"

        @session_id = nil
        initialize_session!
        return rpc(method, renew: false, **params)
      end
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
      if response.code == "404" && @session_id
        raise SessionExpired, "POST #{@uri} (#{body[:method]}): session #{@session_id} is gone"
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

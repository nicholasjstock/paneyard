require "cgi"
require "json"
require "socket"

module FakeTelegram
  # A stand-in for api.telegram.org: the Bot API methods this app calls
  # (RemoteControl::Adapters::Telegram::Client), over real HTTP on a loopback
  # port, so specs drive remote control exactly as the operator's phone does --
  # a message goes in through getUpdates, and what the bot answers comes out
  # of sendMessage/editMessageText/sendRichMessage -- with nothing in between
  # stubbed. Point the client at it with TELEGRAM_BOT_API_URL=#{server.url}.
  #
  # It behaves like Telegram where the app depends on it:
  #   - a wrong token is 401 Unauthorized;
  #   - getUpdates returns updates from `offset` on, and an offset confirms
  #     (drops) every update before it;
  #   - a message's text is its plain text after entity parsing: HTML tags are
  #     stripped and entities decoded, which is also what a reply's
  #     reply_to_message carries and what the 4096-character cap applies to.
  #
  # Plain Ruby, no Rails, one thread per connection.
  class Server
    MAX_MESSAGE_LENGTH = 4096

    Failure = Struct.new(:status, :payload)
    Message = Struct.new(:message_id, :chat_id, :text, :raw, :parse_mode, :kind, :edits, keyword_init: true)

    attr_reader :token, :commands, :requests

    def initialize(token: "123456:fake-token", bot_username: "fake_sandbox_bot")
      @token = token
      @bot_username = bot_username
      @updates = []
      @messages = []
      @requests = []
      @commands = nil
      @next_update_id = 1
      @next_message_id = 1
      @lock = Monitor.new
    end

    def start
      @server = TCPServer.new("127.0.0.1", 0)
      @thread = Thread.new { accept_loop }
      self
    end

    def stop
      @server&.close
      @thread&.kill
    end

    def url
      "http://127.0.0.1:#{@server.addr[1]}"
    end

    # The operator writes to the bot. reply_to: a Message the bot sent.
    def say(text, from: 42, chat_id: from, chat_type: "private", reply_to: nil, is_bot: false)
      @lock.synchronize do
        message = {
          "message_id" => next_message_id, "date" => Time.now.to_i, "text" => text,
          "from" => { "id" => from, "is_bot" => is_bot, "first_name" => "Operator" },
          "chat" => { "id" => chat_id, "type" => chat_type }
        }
        message["reply_to_message"] = { "message_id" => reply_to.message_id, "text" => reply_to.text } if reply_to
        @updates << { "update_id" => (@next_update_id += 1) - 1, "message" => message }
      end
    end

    # Everything the bot sent, oldest first (plain text, as the phone shows it).
    def messages(chat_id: nil)
      @lock.synchronize { @messages.select { |message| chat_id.nil? || message.chat_id.to_s == chat_id.to_s }.dup }
    end

    def texts(chat_id: nil) = messages(chat_id:).map(&:text)

    def calls(method) = @lock.synchronize { @requests.select { |name, _| name == method }.map(&:last) }

    private

    def accept_loop
      loop do
        connection = @server.accept
        Thread.new(connection) { |client| serve(client) }
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def serve(connection)
      request_line = connection.gets or return
      headers = {}
      while (line = connection.gets) && line != "\r\n"
        name, value = line.split(":", 2)
        headers[name.strip.downcase] = value.strip
      end
      body = connection.read(headers["content-length"].to_i)
      path = request_line.split[1].to_s

      status, payload = route(path, body.to_s.empty? ? {} : JSON.parse(body))
      json = JSON.generate(payload)
      connection.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}")
    rescue StandardError => error
      warn "FakeTelegram: #{error.class}: #{error.message}"
    ensure
      connection.close
    end

    def route(path, params)
      token, method = path.delete_prefix("/bot").split("/", 2)
      return [ "401 Unauthorized", { "ok" => false, "error_code" => 401, "description" => "Unauthorized" } ] unless token == @token

      @lock.synchronize { @requests << [ method, params ] }
      result = handle(method, params)
      result.is_a?(Failure) ? result.to_a : [ "200 OK", { "ok" => true, "result" => result } ]
    end

    def handle(method, params)
      case method
      when "getMe" then { "id" => @token.split(":").first.to_i, "is_bot" => true, "username" => @bot_username }
      when "getUpdates" then get_updates(params["offset"].to_i)
      when "sendMessage" then deliver(params, kind: :text, raw: params["text"], parse_mode: params["parse_mode"])
      when "sendRichMessage" then deliver(params, kind: :rich, raw: params.dig("rich_message", "markdown"), parse_mode: "Markdown")
      when "editMessageText" then edit(params)
      when "setMyCommands" then (@commands = params["commands"]) && true
      when "deleteWebhook" then true
      else bad_request("method not found: #{method}")
      end
    end

    def get_updates(offset)
      @lock.synchronize do
        @updates.reject! { |update| update["update_id"] < offset } if offset.positive?
        @updates.dup
      end
    end

    def deliver(params, kind:, raw:, parse_mode:)
      text = plain(raw.to_s, parse_mode)
      return bad_request("message text is empty") if text.strip.empty?
      return bad_request("message is too long") if text.length > MAX_MESSAGE_LENGTH

      message = @lock.synchronize do
        Message.new(message_id: next_message_id, chat_id: params["chat_id"], text:, raw:, parse_mode:, kind:, edits: 0)
          .tap { |sent| @messages << sent }
      end
      { "message_id" => message.message_id, "chat" => { "id" => message.chat_id }, "text" => message.text }
    end

    def edit(params)
      @lock.synchronize do
        message = @messages.find { |sent| sent.message_id == params["message_id"] && sent.chat_id.to_s == params["chat_id"].to_s }
        return bad_request("message to edit not found") unless message

        text = plain(params["text"].to_s, params["parse_mode"])
        return bad_request("message is too long") if text.length > MAX_MESSAGE_LENGTH

        message.text = text
        message.raw = params["text"]
        message.edits += 1
        { "message_id" => message.message_id, "text" => text }
      end
    end

    # What Telegram keeps of a message: its text, trimmed, and for HTML with
    # the tags gone and entities decoded.
    def plain(raw, parse_mode)
      text = parse_mode == "HTML" ? CGI.unescapeHTML(raw.gsub(%r{</?(?:pre|code|b|i|u|s|a)(?:\s[^>]*)?>}, "")) : raw
      text.strip
    end

    def bad_request(description)
      Failure.new("400 Bad Request", { "ok" => false, "error_code" => 400, "description" => "Bad Request: #{description}" })
    end

    def next_message_id
      (@next_message_id += 1) - 1
    end
  end
end

module RemoteControl
  module Adapters
    module Telegram
      # Telegram as a RemoteControl::Adapter: a bot the operator talks to in a
      # private chat. Messages arrive by polling (Poller, run every few seconds
      # by PollTelegramUpdatesJob), so it needs no public URL.
      class Adapter < RemoteControl::Adapter
        def initialize(client: nil)
          @client = client
        end

        def name = "telegram"

        def configured? = Configuration.configured?
        def allowed_user_ids = Configuration.allowed_user_ids
        def max_message_length = Client::MAX_MESSAGE_LENGTH
        def supports_edit? = true

        # The bot's id (the token's part before ":"), never the secret.
        def identity
          "telegram:#{Configuration.bot_token.to_s.split(':').first}"
        end

        # A Bot API update as a RemoteControl::Message, or nil when it is not
        # for us: anything but a message, a bot, or anywhere but the sender's
        # private chat with the bot -- in a group, other members could read
        # panes.
        def message_from(update)
          message = update["message"] or return nil
          user_id = message.dig("from", "id")
          return nil if user_id.nil? || message.dig("from", "is_bot")
          return nil unless message.dig("chat", "type") == "private" && message.dig("chat", "id").to_s == user_id.to_s

          RemoteControl::Message.new(
            chat_id: message.dig("chat", "id"), user_id:,
            # "/panes@my_bot" is how Telegram writes a command picked from the
            # menu in some clients.
            text: message["text"].to_s.strip.sub(%r{\A(/\w+)@\w+}, '\1'),
            reply_to_text: message.dig("reply_to_message", "text")
          )
        end

        def send_text(chat_id, text)
          message_id(client.send_message(chat_id:, text:))
        end

        def send_pane(chat_id, title, body)
          message_id(client.send_message(chat_id:, parse_mode: "HTML", text: pane_html(title, body)))
        end

        def edit_pane(chat_id, message_id, title, body)
          client.edit_message_text(chat_id:, message_id:, parse_mode: "HTML", text: pane_html(title, body))
        end

        # Renders a checkpoint's Markdown (headings, tables, fences) natively.
        def send_markdown(chat_id, markdown)
          message_id(client.send_rich_message(chat_id:, markdown:))
        end

        # Telegram makes "/pane_33bd" tappable; "/pane 33bd" is not.
        def command_link(command, ref)
          "/#{command}_#{ref}"
        end

        def publish_commands(commands)
          client.set_my_commands(commands)
        end

        def client
          @client ||= Client.new
        end

        private

        # Telegram's 4096-character cap counts text after entity parsing, so
        # the escaping here does not eat into pane_capacity.
        def pane_html(title, body)
          "#{ERB::Util.html_escape(title)}\n<pre>#{ERB::Util.html_escape(body.presence || ' ')}</pre>"
        end

        def message_id(result)
          result["message_id"] if result.is_a?(Hash)
        end
      end
    end
  end
end

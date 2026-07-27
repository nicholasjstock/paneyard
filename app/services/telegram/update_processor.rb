module Telegram
  class UpdateProcessor
    WORKSPACE_CALLBACK_PREFIX = "workspace:".freeze

    def self.call(update)
      new(update.deep_stringify_keys).call
    end

    def initialize(update)
      @update = update
      @client = Client.new
    end

    def call
      return handle_callback(@update.fetch("callback_query")) if @update["callback_query"]

      handle_message(@update.fetch("message")) if @update["message"]
    end

    private

    def handle_message(message)
      return unless authorized?(message.dig("from", "id"))

      conversation = conversation_for(message)
      text = message["text"].to_s.strip
      return show_workspaces(conversation) if text.in?([ "/start", "/workspaces" ])
      return cancel_turn(conversation) if text == "/stop"
      return @client.send_message(chat_id: conversation.telegram_chat_id, text: "Choose a workspace first with /workspaces.") unless conversation.workspace
      return @client.send_message(chat_id: conversation.telegram_chat_id, text: "That workspace is still working. Send /stop to cancel it.") if conversation.workspace.workspace_admin_chat&.active?

      chat = conversation.workspace.workspace_admin_chat || conversation.workspace.create_workspace_admin_chat!
      assistant_message = Orchestrator::WorkspaceAdminChatDriver::Runner.start_turn!(chat:, content: text, telegram_conversation: conversation)
      start_live_response(assistant_message, conversation)
    end

    def start_live_response(assistant_message, conversation)
      draft_id = SecureRandom.random_number(1..(2**63 - 1))
      @client.send_rich_message_draft(
        chat_id: conversation.telegram_chat_id, draft_id:,
        html: "<tg-thinking>Working in #{ERB::Util.html_escape(conversation.workspace.name)}…</tg-thinking>"
      )
      assistant_message.update!(telegram_draft_id: draft_id)
    end

    def handle_callback(callback)
      return unless authorized?(callback.dig("from", "id"))

      conversation = conversation_for(callback.fetch("message").merge("from" => callback.fetch("from")))
      workspace_id = callback["data"].to_s.delete_prefix(WORKSPACE_CALLBACK_PREFIX)
      workspace = Workspace.find_by(id: workspace_id)
      return unless callback["data"].to_s.start_with?(WORKSPACE_CALLBACK_PREFIX) && workspace

      conversation.update!(workspace:)
      @client.answer_callback_query(callback_query_id: callback.fetch("id"))
      @client.send_message(chat_id: conversation.telegram_chat_id, text: "Selected #{workspace.name}. Send a message to its admin chat.")
    end

    def cancel_turn(conversation)
      chat = conversation.workspace&.workspace_admin_chat
      cancelled = chat && Orchestrator::WorkspaceAdminChatDriver::Runner.cancel_turn!(chat)
      @client.send_message(chat_id: conversation.telegram_chat_id, text: cancelled ? "Cancelling #{conversation.workspace.name}." : "There is no active admin-chat turn.")
    end

    def show_workspaces(conversation)
      buttons = Workspace.order(:name).map { |workspace| [ { text: workspace.name, callback_data: "#{WORKSPACE_CALLBACK_PREFIX}#{workspace.id}" } ] }
      @client.send_message(chat_id: conversation.telegram_chat_id, text: "Choose a workspace:", reply_markup: { inline_keyboard: buttons })
    end

    def conversation_for(message)
      TelegramConversation.find_or_initialize_by(telegram_chat_id: message.dig("chat", "id").to_s).tap do |conversation|
        conversation.telegram_user_id = message.dig("from", "id").to_s
        conversation.save!
      end
    end

    def authorized?(telegram_user_id)
      Configuration.authorized_user?(telegram_user_id.to_s)
    end
  end
end

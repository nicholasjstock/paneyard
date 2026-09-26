module McpTools
  # Resolves the WorkspaceAdminChat behind an admin-chat MCP call, and is the
  # single place the workspace boundary is enforced: a chat may only ever see
  # and steer runs in its own workspace.
  module AdminChatAuthorization
    module_function

    def chat!(server_context:)
      # Direct service specs exercise tool classes without an HTTP transport.
      return if Rails.env.test? && context_value(server_context, :admin_chat_id).blank?

      chat = WorkspaceAdminChat.find_by(id: context_value(server_context, :admin_chat_id))
      raise ArgumentError, "authenticated admin chat required" unless chat

      chat
    end

    # Scopes a run lookup to the calling chat's workspace. A chat asking about
    # a run id from another workspace gets "no such run", not that run.
    def run!(server_context:, run_id:)
      chat = chat!(server_context:)
      scope = chat ? chat.workspace.runs : Run
      scope.find_by(run_id:) || raise(ArgumentError, "no run #{run_id} in this workspace")
    end

    def context_value(server_context, key)
      return server_context[key] if server_context.respond_to?(:[])

      nil
    end
    private_class_method :context_value
  end
end

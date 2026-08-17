module McpTools
  # Resolves the RunSession behind an MCP call. Replaces WorkerAuthorization:
  # the capability now belongs to a run's one session rather than to one of
  # many per-step workers.
  module SessionAuthorization
    module_function

    def session!(server_context:, run_id: nil)
      # Direct service specs exercise tool classes without an HTTP transport.
      return if Rails.env.test? && context_value(server_context, :run_session_id).blank?

      session = RunSession.live.find_by(id: context_value(server_context, :run_session_id))
      raise ArgumentError, "authenticated live run session required" unless session
      raise ArgumentError, "session capability does not belong to run #{run_id}" if run_id.present? && session.run.run_id != run_id

      session
    end

    def context_value(server_context, key)
      return server_context[key] if server_context.respond_to?(:[])

      nil
    end
    private_class_method :context_value
  end
end

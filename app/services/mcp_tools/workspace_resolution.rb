module McpTools
  # Resolves which Workspace a queue_run/list_runs/get_run call applies to.
  # Unlike SessionAuthorization/AdminChatAuthorization this is not a
  # capability gate -- both call sites are already trusted (a run session's
  # own bearer token, or the unauthenticated local /mcp/admin endpoint,
  # matching this app's no-runtime-auth design) -- it only picks a sensible
  # default so a caller doesn't have to state the obvious every time.
  #
  # Resolution order: an explicit `workspace:` name always wins, so any
  # caller can reach any registered workspace; absent that, a run session's
  # own workspace (a session queuing follow-up work defaults to "here");
  # absent that too (the bare /mcp/admin endpoint has no run session behind
  # it), the oldest registered workspace.
  module WorkspaceResolution
    module_function

    def resolve!(server_context:, workspace: nil)
      return find_named!(workspace) if workspace.present?

      run_session_id = context_value(server_context, :run_session_id)
      if run_session_id.present?
        session = RunSession.find_by(id: run_session_id)
        return session.run.workspace if session
      end

      Workspace.default || raise(ArgumentError, "no workspace is registered")
    end

    def run!(server_context:, run_id:, workspace: nil)
      resolved = resolve!(server_context:, workspace:)
      resolved.runs.find_by(run_id:) || raise(ArgumentError, "no run #{run_id} in workspace #{resolved.name.inspect}")
    end

    def find_named!(name)
      Workspace.find_by(name:) ||
        raise(ArgumentError, "no workspace named #{name.inspect}; registered: #{Workspace.order(:created_at).pluck(:name).join(', ')}")
    end
    private_class_method :find_named!

    def context_value(server_context, key)
      return server_context[key] if server_context.respond_to?(:[])

      nil
    end
    private_class_method :context_value
  end
end

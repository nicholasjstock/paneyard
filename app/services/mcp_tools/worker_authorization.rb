module McpTools
  module WorkerAuthorization
    module_function

    def worker!(server_context:, run_id: nil)
      # Direct service specs exercise tool classes without an HTTP transport.
      return if Rails.env.test? && context_value(server_context, :worker_id).blank?

      worker_id = context_value(server_context, :worker_id)
      worker = Worker.find_by(worker_id:, status: %w[launching running])
      raise ArgumentError, "authenticated active worker required" unless worker
      raise ArgumentError, "worker capability does not belong to run #{run_id}" if run_id.present? && worker.run_id != run_id

      worker
    end

    def context_value(server_context, key)
      return server_context[key] if server_context.respond_to?(:[])

      nil
    end
    private_class_method :context_value
  end
end

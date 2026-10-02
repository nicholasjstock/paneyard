module McpTools
  # The models a driver's CLI offers on the runner's machine, for a caller
  # choosing queue_run's model (the herdr plugin's queue popup). Admin-only:
  # a run session queueing follow-up work has no picker to fill.
  class ListModelsTool < MCP::Tool
    tool_name "list_models"
    description "List the model ids queue_run accepts as model for a driver: what that agent CLI, as installed " \
      "where runs start, says it offers, and defaultModel, which a run gets when model is left out (null: the " \
      "CLI's own configured default)."
    input_schema(
      properties: {
        driver: { type: "string", enum: Run::LAUNCHER_VARIANTS },
        workspace: { type: "string", description: "Workspace whose runner to ask (default: the default workspace)." }
      },
      required: %w[driver]
    )

    def self.call(driver:, server_context:, workspace: nil)
      raise ArgumentError, "driver must be one of #{Run::LAUNCHER_VARIANTS.join(', ')}" unless Run::LAUNCHER_VARIANTS.include?(driver)

      target = WorkspaceResolution.resolve!(server_context:, workspace:)
      ToolResponse.structured(
        driver:,
        default_model: Orchestrator::DefaultModels.for(driver),
        models: Orchestrator::ModelCatalog.options_for(driver, target)
      )
    rescue ArgumentError => error
      ToolResponse.error(error.message)
    end
  end
end

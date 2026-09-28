module Orchestrator
  # The model a run's session gets when the operator did not pick one.
  #
  # There is no small/strong model tier any more (that was a planner concept --
  # a bounded decision could run cheap, a real step could not). A session now
  # owns an entire job end to end, so each driver gets its strongest configured
  # model, overridable per driver by env var for experimentation -- and per
  # run by the model the operator picked when queueing it (Run#model, chosen
  # from Orchestrator::ModelCatalog), which wins over both.
  module DefaultModels
    module_function

    def for(driver)
      case driver
      when "claude" then ENV["WORKFLOW_CLAUDE_MODEL"].presence || "opus"
      when "codex" then ENV["WORKFLOW_CODEX_MODEL"].presence || "gpt-5.6-terra"
      when "opencode" then ENV["WORKFLOW_OPENCODE_MODEL"].presence || "9router/oc/deepseek-v4-flash-free"
      end
    end
  end
end

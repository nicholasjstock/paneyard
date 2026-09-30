module Orchestrator
  # The model a run's session gets when the operator did not pick one.
  #
  # There is no small/strong model tier any more (that was a planner concept --
  # a bounded decision could run cheap, a real step could not). A session now
  # owns an entire job end to end. claude gets `opus`, an alias every claude
  # install understands. codex and opencode get nil: no model flag at all, so
  # the CLI runs whatever model it is itself configured with (codex's own
  # default, opencode's `model` setting) -- their model ids depend on the
  # account and on which providers are set up, so no hardcoded id works for
  # everyone. Each is overridable per driver by env var, and per run by the
  # model the operator picked when queueing it (Run#model, chosen from
  # Orchestrator::ModelCatalog), which wins over both.
  module DefaultModels
    module_function

    def for(driver)
      case driver
      when "claude" then ENV["PANEYARD_CLAUDE_MODEL"].presence || "opus"
      when "codex" then ENV["PANEYARD_CODEX_MODEL"].presence
      when "opencode" then ENV["PANEYARD_OPENCODE_MODEL"].presence
      end
    end
  end
end

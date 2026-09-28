module Orchestrator
  # The models the new-run form offers for each driver: what the workspace's
  # runner reports its installed CLIs can run (Runner::ModelDiscovery),
  # cached briefly so rendering the form does not run three CLIs every time.
  module ModelCatalog
    module_function

    CACHE_TTL = 10.minutes

    # [{ "id" => "claude-opus-5-5", "label" => "Opus 5.5 — claude-opus-5-5" }, ...]
    def options_for(driver, workspace)
      runner = Runner.for(workspace)
      Rails.cache.fetch("orchestrator/model_catalog/#{runner.id}/#{driver}", expires_in: CACHE_TTL, skip_nil: true) do
        runner.available_models(driver).presence
      end || []
    end

    def all(workspace)
      Run::LAUNCHER_VARIANTS.index_with { |driver| options_for(driver, workspace) }
    end
  end
end

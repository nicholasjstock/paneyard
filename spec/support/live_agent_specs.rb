RSpec.configure do |config|
  config.filter_run_excluding live_agent: true unless ENV["LIVE_AGENT_SPECS"] == "1"
end

module LiveAgentSpecs
  module_function

  def enabled?
    ENV["LIVE_AGENT_SPECS"] == "1"
  end

  def variants
    raw = ENV.fetch("LIVE_AGENT_VARIANTS", "claude,codex")
    raw.split(",").map(&:strip).reject(&:empty?)
  end

  def timeout_seconds
    ENV.fetch("LIVE_AGENT_TIMEOUT_SECONDS", "180").to_i
  end

  def workspace_root_for(variant)
    specific = ENV["LIVE_AGENT_#{variant.upcase}_WORKSPACE_ROOT"]
    return specific if specific.present?

    ENV["LIVE_AGENT_WORKSPACE_ROOT"]
  end
end

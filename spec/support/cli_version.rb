# A lost prompt's record asks the agent CLI for its version (SessionLauncher's
# cli_version), which specs must not run: the operator's own claude or codex.
RSpec.configure do |config|
  config.before do
    allow(Orchestrator::Runner::SessionLauncher).to receive(:cli_version) { |kind| "#{kind} 9.9.9 (spec)" }
  end
end

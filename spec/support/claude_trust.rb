# Launching a Claude run marks its worktree as trusted in Claude's own config,
# which specs must never write. ClaudeTrust's own examples opt out.
RSpec.configure do |config|
  config.before do |example|
    allow(Orchestrator::Runner::ClaudeTrust).to receive(:trust!).and_return(true) unless example.metadata[:claude_trust]
  end
end

# Launching a claude or codex run marks its worktree as trusted in the CLI's
# own config, which specs must never write. ClaudeTrust's and CodexTrust's own
# examples opt out.
RSpec.configure do |config|
  config.before do |example|
    unless example.metadata[:claude_trust]
      allow(Orchestrator::Runner::ClaudeTrust).to receive(:trust!).and_return(true)
      allow(Orchestrator::Runner::CodexTrust).to receive(:trust!).and_return(true)
    end
  end
end

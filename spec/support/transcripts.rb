# Ending a session copies the CLI's own transcripts out of claude's and
# codex's config, which specs must never read: point both at empty
# directories of the suite's own. Tag `:transcripts` to set them yourself.
TRANSCRIPT_SOURCES_ROOT = Dir.mktmpdir("paneyard-spec-transcript-sources")
at_exit { FileUtils.rm_rf(TRANSCRIPT_SOURCES_ROOT) }

RSpec.configure do |config|
  config.before do |example|
    next if example.metadata[:transcripts]

    allow(Orchestrator::Runner::Transcripts).to receive(:claude_config_dir).and_return(File.join(TRANSCRIPT_SOURCES_ROOT, "claude"))
    allow(Orchestrator::Runner::Transcripts).to receive(:codex_home).and_return(File.join(TRANSCRIPT_SOURCES_ROOT, "codex"))
  end
end

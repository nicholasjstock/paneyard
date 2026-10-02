require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../../../lib/paneyard_plugin"

# Against files shaped like the CLIs' own session logs.
RSpec.describe PaneyardPlugin::SessionModel do
  let(:home) { Dir.mktmpdir("paneyard-session-model") }
  let(:env) { { "HOME" => home } }
  let(:session_id) { "bac93926-fd8d-4fbc-8b53-51d1d5bd294d" }

  after { FileUtils.rm_rf(home) }

  def write_log(path, entries)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, entries.map { |entry| JSON.generate(entry) + "\n" }.join)
  end

  def assistant(model) = { "type" => "assistant", "message" => { "role" => "assistant", "model" => model } }
  def user(content) = { "type" => "user", "message" => { "role" => "user", "content" => content } }

  describe "claude" do
    let(:log) { File.join(home, ".claude", "projects", "-code-app", "#{session_id}.jsonl") }

    it "is the model of the newest reply, which follows a /model switch" do
      write_log(log, [ assistant("claude-opus-5-5"), user("<local-command-stdout>Set model to `Sonnet 5.5`</local-command-stdout>"),
        assistant("claude-sonnet-5-5"), assistant("<synthetic>") ])

      expect(described_class.for("claude", session_id, env:)).to have_attributes(id: "claude-sonnet-5-5", switched_to: nil)
    end

    it "reports a /model switch with no reply since by its display name" do
      write_log(log, [ assistant("claude-opus-5-5"),
        user("<local-command-stdout>Set model to `Sonnet 5.5` and saved as your default for new sessions</local-command-stdout>") ])

      expect(described_class.for("claude", session_id, env:)).to have_attributes(id: "claude-opus-5-5", switched_to: "Sonnet 5.5")
    end

    it "looks in CLAUDE_CONFIG_DIR and ~/.config/claude too" do
      write_log(File.join(home, ".config", "claude", "projects", "-code-app", "#{session_id}.jsonl"), [ assistant("claude-haiku-4-5") ])

      expect(described_class.for("claude", session_id, env:).id).to eq("claude-haiku-4-5")
    end

    it "reads only the tail of a long log" do
      stub_const("#{described_class}::TAIL_BYTES", 200)
      write_log(log, [ assistant("old-model"), user("x" * 500), assistant("claude-opus-5-5") ])

      expect(described_class.for("claude", session_id, env:).id).to eq("claude-opus-5-5")
    end
  end

  describe "codex" do
    it "is the model of the newest turn" do
      write_log(File.join(home, ".codex", "sessions", "2026", "10", "02", "rollout-2026-10-02T10-00-00-#{session_id}.jsonl"), [
        { "type" => "session_meta", "payload" => { "id" => session_id } },
        { "type" => "turn_context", "payload" => { "model" => "gpt-5.5" } },
        { "type" => "turn_context", "payload" => { "model" => "gpt-5.4-mini" } }
      ])

      expect(described_class.for("codex", session_id, env:).id).to eq("gpt-5.4-mini")
    end
  end

  it "follows a codex /model switch at once, from the event it logs, and finds the log under ~/.config/codex" do
    write_log(File.join(home, ".config", "codex", "sessions", "2026", "10", "02", "rollout-2026-10-02T08-28-20-#{session_id}.jsonl"), [
      { "type" => "turn_context", "payload" => { "model" => "gpt-5.6-luna" } },
      { "type" => "event_msg", "payload" => { "type" => "agent_message", "message" => "ok" } },
      { "type" => "event_msg", "payload" => { "type" => "thread_settings_applied", "thread_id" => session_id,
        "thread_settings" => { "model" => "gpt-6-luna", "model_provider_id" => "openai" } } }
    ])

    expect(described_class.for("codex", session_id, env:).id).to eq("gpt-6-luna")
  end

  it "is nil with no log, or a session id that could reach outside the log directories" do
    expect(described_class.for("claude", session_id, env:)).to be_nil
    expect(described_class.for("claude", "../../etc/passwd", env:)).to be_nil
    expect(described_class.for("codex", nil, env:)).to be_nil
  end
end

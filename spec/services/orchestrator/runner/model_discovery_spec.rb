require "rails_helper"

RSpec.describe Orchestrator::Runner::ModelDiscovery do
  describe ".models_for claude" do
    around do |example|
      original = ENV["CLAUDE_CONFIG_DIR"]
      Dir.mktmpdir("claude-config") do |dir|
        ENV["CLAUDE_CONFIG_DIR"] = dir
        example.run
      end
    ensure
      ENV["CLAUDE_CONFIG_DIR"] = original
    end

    def write_catalog(name, models, mtime: Time.current)
      dir = File.join(ENV["CLAUDE_CONFIG_DIR"], "cache", "model-catalog")
      FileUtils.mkdir_p(dir)
      path = File.join(dir, name)
      File.write(path, JSON.generate({ "catalog" => { "config" => { "models" => models } } }))
      File.utime(mtime.to_time, mtime.to_time, path)
    end

    it "reads the catalog claude cached for its own model picker, newest file first" do
      write_catalog("old-cc.json", [ { "id" => "claude-old", "name" => "Old" } ], mtime: 1.day.ago)
      write_catalog("new-cc.json", [
        { "id" => "claude-opus-5-5", "name" => "Opus 5.5" },
        { "id" => "claude-sonnet-5", "name" => "Sonnet 5" }
      ])

      expect(described_class.models_for("claude")).to eq([
        { "id" => "claude-opus-5-5", "label" => "Opus 5.5 — claude-opus-5-5" },
        { "id" => "claude-sonnet-5", "label" => "Sonnet 5 — claude-sonnet-5" }
      ])
    end

    it "is empty when claude has never cached a catalog" do
      allow(Dir).to receive(:glob).and_return([])

      expect(described_class.models_for("claude")).to eq([])
    end
  end

  describe ".models_for codex" do
    it "lists codex's own catalog in its priority order, leaving out hidden models" do
      allow(described_class).to receive(:capture).with("codex", "debug", "models").and_return(JSON.generate({
        "models" => [
          { "slug" => "gpt-5.5", "display_name" => "GPT-5.5", "visibility" => "list", "priority" => 12 },
          { "slug" => "codex-auto-review", "display_name" => "Codex Auto Review", "visibility" => "hide", "priority" => 43 },
          { "slug" => "gpt-6-astra", "display_name" => "GPT-6-Astra", "visibility" => "list", "priority" => 1 }
        ]
      }))

      expect(described_class.models_for("codex")).to eq([
        { "id" => "gpt-6-astra", "label" => "gpt-6-astra" },
        { "id" => "gpt-5.5", "label" => "gpt-5.5" }
      ])
    end

    it "is empty rather than an error when codex output is unusable" do
      allow(described_class).to receive(:capture).and_return("not json")

      expect(described_class.models_for("codex")).to eq([])
    end
  end

  it "lists nothing for opencode, which is no longer a driver" do
    expect(described_class.models_for("opencode")).to eq([])
  end

  describe ".capture" do
    it "returns nil for a CLI that is not installed" do
      expect(described_class.capture("definitely-not-a-real-cli-#{SecureRandom.hex(4)}")).to be_nil
    end

    it "returns nil for a failing command and stdout for a successful one" do
      expect(described_class.capture("false")).to be_nil
      expect(described_class.capture("echo", "hi")).to eq("hi\n")
    end

    it "gives up on a CLI that hangs" do
      stub_const("#{described_class}::COMMAND_TIMEOUT_SECONDS", 0.2)

      expect(described_class.capture("sleep", "5")).to be_nil
    end
  end
end

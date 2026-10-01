require "spec_helper"
require "tmpdir"
require_relative "../../../lib/paneyard_plugin"

RSpec.describe PaneyardPlugin::EnvFile do
  describe ".parse" do
    it "reads dotenv lines" do
      values, warnings = described_class.parse(<<~ENV)
        # a comment
        PANEYARD_MAX_CONCURRENT_RUNS=2
        export PANEYARD_CLAUDE_MODEL = sonnet   # trailing comment
        SINGLE='kept # as $is'
        DOUBLE="a\\tb \\"quoted\\" \\\\ end"
        EMPTY=
      ENV

      expect(warnings).to be_empty
      expect(values).to eq(
        "PANEYARD_MAX_CONCURRENT_RUNS" => "2", "PANEYARD_CLAUDE_MODEL" => "sonnet",
        "SINGLE" => "kept # as $is", "DOUBLE" => "a\tb \"quoted\" \\ end", "EMPTY" => ""
      )
    end

    it "reads a double-quoted value across lines, as a private key is pasted" do
      values, = described_class.parse(<<~ENV)
        GITHUB_APP_PRIVATE_KEY="-----BEGIN RSA PRIVATE KEY-----
        MIIabc
        -----END RSA PRIVATE KEY-----"
        AFTER=1
      ENV

      expect(values["GITHUB_APP_PRIVATE_KEY"]).to eq("-----BEGIN RSA PRIVATE KEY-----\nMIIabc\n-----END RSA PRIVATE KEY-----")
      expect(values["AFTER"]).to eq("1")
    end

    it "warns about lines it cannot read instead of guessing" do
      values, warnings = described_class.parse("not a setting\n1BAD=x\nOPEN=\"never closed\nOK=yes\n")

      expect(values).to eq({})
      expect(warnings.join("\n")).to include("line 1", "line 2", "OPEN has no closing double quote")
    end

    it "parses its own sample to nothing" do
      expect(described_class.parse(described_class::SAMPLE)).to eq([ {}, [] ])
    end
  end

  describe ".load" do
    it "drops the keys the plugin decides itself" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".env")
        File.write(path, "RAILS_ENV=development\nHERDR_SOCKET_PATH=/elsewhere\nPANEYARD_STORAGE_DIR=/x\nPORT=7300\n")

        values, warnings = described_class.load(path)

        expect(values).to eq("PORT" => "7300")
        expect(warnings.join("\n")).to include("RAILS_ENV", "HERDR_SOCKET_PATH", "PANEYARD_STORAGE_DIR")
      end
    end

    it "is empty when there is no file" do
      expect(described_class.load("/nonexistent/.env")).to eq([ {}, [] ])
    end
  end

  describe ".write_sample" do
    it "writes the sample once and never overwrites the operator's file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "config", ".env")

        expect(described_class.write_sample(path)).to be(true)
        expect(File.read(path)).to eq(described_class::SAMPLE)
        expect(File.stat(path).mode & 0o777).to eq(0o600)

        File.write(path, "PANEYARD_MAX_CONCURRENT_RUNS=1\n")
        expect(described_class.write_sample(path)).to be(false)
        expect(File.read(path)).to eq("PANEYARD_MAX_CONCURRENT_RUNS=1\n")
      end
    end
  end
end

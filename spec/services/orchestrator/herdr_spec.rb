require "rails_helper"

RSpec.describe Orchestrator::Herdr do
  describe ".workspace_create" do
    it "passes label/cwd/focus through and stringifies the env, dropping nil-valued entries" do
      expect(described_class).to receive(:request!).with(
        "workspace.create", label: "run-1", cwd: "/tmp/run-1", env: { "FOO" => "bar baz" }, focus: false
      ).and_return("root_pane" => { "pane_id" => "w9:p1", "tab_id" => "w9:t1", "workspace_id" => "w9" })

      result = described_class.workspace_create(
        label: "run-1", cwd: "/tmp/run-1", env: { "FOO" => "bar baz", "DROP_ME" => nil }
      )

      expect(result.fetch("root_pane").fetch("pane_id")).to eq("w9:p1")
    end
  end

  describe ".workspace_alive?" do
    it "is true while herdr still knows the workspace" do
      allow(described_class).to receive(:request!).with("workspace.get", workspace_id: "w1").and_return({})

      expect(described_class.workspace_alive?("w1")).to be true
    end

    it "is false once the operator has closed it by hand, and for a blank id" do
      allow(described_class).to receive(:request!).with("workspace.get", workspace_id: "w1")
        .and_raise(described_class::Error, "workspace not found")

      expect(described_class.workspace_alive?("w1")).to be false
      expect(described_class.workspace_alive?(nil)).to be false
    end
  end

  describe ".pane_alive?" do
    it "reports pane liveness and treats a blank id as dead" do
      allow(described_class).to receive(:request!).with("pane.get", pane_id: "w1:p1").and_return({})
      expect(described_class.pane_alive?("w1:p1")).to be true

      allow(described_class).to receive(:request!).with("pane.get", pane_id: "w1:p2")
        .and_raise(described_class::Error, "pane_not_found")
      expect(described_class.pane_alive?("w1:p2")).to be false
      expect(described_class.pane_alive?("")).to be false
    end
  end

  describe ".agent_get" do
    it "unwraps the agent envelope" do
      allow(described_class).to receive(:request!).with("agent.get", target: "w1:p1")
        .and_return("agent" => { "interactive_ready" => true, "agent_status" => "working" })

      expect(described_class.agent_get("w1:p1")).to include("agent_status" => "working")
    end
  end

  describe ".pane_read" do
    it "returns the pane text and only sends lines when a limit is given" do
      expect(described_class).to receive(:request!).with(
        "pane.read", pane_id: "w1:p1", source: "recent", strip_ansi: true
      ).and_return("text" => "all of it")
      expect(described_class.pane_read("w1:p1")).to eq("all of it")

      expect(described_class).to receive(:request!).with(
        "pane.read", pane_id: "w1:p1", source: "visible", strip_ansi: true, lines: 40
      ).and_return("text" => "just the tail")
      expect(described_class.pane_read("w1:p1", source: "visible", lines: 40)).to eq("just the tail")
    end
  end

  describe ".notify" do
    it "never lets a notification failure escape into the caller's real work" do
      allow(described_class).to receive(:request).and_raise(described_class::Error, "herdr is not running")

      expect { described_class.notify(title: "Run finished") }.not_to raise_error
    end
  end

  describe ".request" do
    it "wraps a connection failure as a Herdr::Error" do
      allow(UNIXSocket).to receive(:new).and_raise(Errno::ENOENT, "no such file or directory")

      expect { described_class.request!("ping") }.to raise_error(described_class::Error, /herdr is not running/)
    end

    it "raises when herdr answers with an error envelope" do
      allow(described_class).to receive(:request).with("agent.get", target: "w1:p1")
        .and_return("error" => { "code" => "pane_not_found", "message" => "no such pane" })

      expect { described_class.request!("agent.get", target: "w1:p1") }
        .to raise_error(described_class::Error, "no such pane")
    end
  end
end

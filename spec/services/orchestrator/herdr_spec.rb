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

  describe ".pane_split" do
    # The live shape (herdr 0.7.5): {"type" => "pane_info", "pane" => {...}}.
    it "splits the target pane and unwraps the new pane" do
      expect(described_class).to receive(:request!).with(
        "pane.split", target_pane_id: "w1:p1", direction: "right", cwd: "/tmp/run-1", focus: false
      ).and_return("type" => "pane_info", "pane" => { "pane_id" => "w1:p2", "workspace_id" => "w1" })

      pane = described_class.pane_split(target_pane_id: "w1:p1", direction: "right", cwd: "/tmp/run-1")

      expect(pane.fetch("pane_id")).to eq("w1:p2")
    end
  end

  describe ".pane_read" do
    # The live shape (herdr 0.7.5, protocol 17). This spec previously asserted a
    # flat {"text" => ...}, which is why every real pane read raised KeyError.
    it "unwraps the nested read envelope and only sends lines when a limit is given" do
      expect(described_class).to receive(:request!).with(
        "pane.read", pane_id: "w1:p1", source: "recent", strip_ansi: true
      ).and_return("type" => "pane_read", "read" => { "pane_id" => "w1:p1", "text" => "all of it" })
      expect(described_class.pane_read("w1:p1")).to eq("all of it")

      expect(described_class).to receive(:request!).with(
        "pane.read", pane_id: "w1:p1", source: "visible", strip_ansi: true, lines: 40
      ).and_return("type" => "pane_read", "read" => { "text" => "just the tail" })
      expect(described_class.pane_read("w1:p1", source: "visible", lines: 40)).to eq("just the tail")
    end

    it "still accepts a flat text payload" do
      allow(described_class).to receive(:request!).and_return("text" => "flat")

      expect(described_class.pane_read("w1:p1")).to eq("flat")
    end

    # A Herdr::Error, not a KeyError: RunSessionRunner.snapshot rescues the
    # former to degrade to nil instead of taking the run screen down with a 500.
    it "raises a Herdr::Error when the response carries no text at all" do
      allow(described_class).to receive(:request!).and_return("type" => "pane_read", "read" => {})

      expect { described_class.pane_read("w1:p1") }
        .to raise_error(described_class::Error, /no text/)
    end
  end

  describe ".notify" do
    it "never lets a notification failure escape into the caller's real work" do
      allow(described_class).to receive(:request).and_raise(described_class::Error, "herdr is not running")

      expect { described_class.notify(title: "Run finished") }.not_to raise_error
    end
  end

  describe ".request" do
    it "wraps a connection failure as a Herdr::Unreachable" do
      allow(UNIXSocket).to receive(:new).and_raise(Errno::ENOENT, "no such file or directory")

      expect { described_class.request!("ping") }
        .to raise_error(described_class::Unreachable, /herdr is not running/)
    end

    # Regression: RunSessionRunner.refresh! must be able to tell "herdr never
    # answered" apart from "herdr answered and said no such pane" -- conflating
    # them once caused a socket blip to permanently fail a run whose session
    # had already reported done. Unreachable is a Herdr::Error subclass, so
    # every existing `rescue Herdr::Error` still catches it.
    it "raises Unreachable, not a bare Error, for a timeout" do
      allow(Timeout).to receive(:timeout).and_raise(Timeout::Error)

      expect { described_class.request!("agent.get", target: "w1:p1") }
        .to raise_error(described_class::Unreachable, /timed out/)
    end

    it "raises Unreachable when herdr sends back unparseable JSON" do
      socket = instance_double(UNIXSocket, write: nil, gets: "not json", close: nil)
      allow(UNIXSocket).to receive(:new).and_return(socket)

      expect { described_class.request!("agent.get", target: "w1:p1") }
        .to raise_error(described_class::Unreachable, /unparseable/)
    end

    it "raises Unreachable when the socket closes without a line back" do
      socket = instance_double(UNIXSocket, write: nil, gets: nil, close: nil)
      allow(UNIXSocket).to receive(:new).and_return(socket)

      expect { described_class.request!("agent.get", target: "w1:p1") }
        .to raise_error(described_class::Unreachable, /closed without a response/)
    end

    it "raises a plain Error, not Unreachable, when herdr answers with an error envelope" do
      allow(described_class).to receive(:request).with("agent.get", target: "w1:p1")
        .and_return("error" => { "code" => "pane_not_found", "message" => "no such pane" })

      error = nil
      begin
        described_class.request!("agent.get", target: "w1:p1")
      rescue described_class::Error => e
        error = e
      end

      expect(error.message).to eq("no such pane")
      expect(error).not_to be_a(described_class::Unreachable)
    end
  end
end

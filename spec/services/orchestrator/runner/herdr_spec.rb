require "rails_helper"

RSpec.describe Orchestrator::Runner::Herdr do
  describe ".worktree_create" do
    # herdr chooses where the worktree goes: no path is ever sent.
    it "asks herdr for a worktree of the repository on a branch from a base, unfocused" do
      expect(described_class).to receive(:request!).with(
        "worktree.create", cwd: "/code/app", branch: "paneyard/fix-1", base: "feature/payments", label: "fix-1", focus: false
      ).and_return("workspace" => { "workspace_id" => "w9" }, "worktree" => { "path" => "/wt/fix-1" })

      result = described_class.worktree_create(cwd: "/code/app", branch: "paneyard/fix-1", base: "feature/payments", label: "fix-1")

      expect(result.dig("worktree", "path")).to eq("/wt/fix-1")
    end
  end

  describe ".worktree_open / .worktree_remove / .tab_close / .pane_list" do
    it "sends what herdr's schema takes" do
      expect(described_class).to receive(:request!).with("worktree.open", cwd: "/code/app", path: "/wt/fix-1", focus: false)
        .and_return("workspace" => { "workspace_id" => "w9" })
      expect(described_class).to receive(:request!).with("worktree.remove", workspace_id: "w9", force: false)
      expect(described_class).to receive(:request!).with("tab.close", tab_id: "w9:t1")
      expect(described_class).to receive(:request!).with("pane.list", workspace_id: "w9").and_return("panes" => [ { "pane_id" => "w9:p1" } ])

      described_class.worktree_open(cwd: "/code/app", path: "/wt/fix-1")
      described_class.worktree_remove("w9")
      described_class.tab_close("w9:t1")
      expect(described_class.pane_list(workspace_id: "w9")).to eq([ { "pane_id" => "w9:p1" } ])
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

    it "passes a ratio when given, and never an env" do
      expect(described_class).to receive(:request!).with(
        "pane.split", target_pane_id: "w1:p1", direction: "down", cwd: "/tmp/run-1", focus: false, ratio: 0.3
      ).and_return("pane" => { "pane_id" => "w1:p2" })

      described_class.pane_split(target_pane_id: "w1:p1", direction: "down", cwd: "/tmp/run-1", ratio: 0.3)
    end
  end

  describe ".tab_create" do
    it "opens an unfocused tab and returns the tab and its root pane" do
      expect(described_class).to receive(:request!).with(
        "tab.create", workspace_id: "w1", label: "logs", cwd: "/tmp/run-1", focus: false
      ).and_return("tab" => { "tab_id" => "w1:t2" }, "root_pane" => { "pane_id" => "w1:p3" })

      result = described_class.tab_create(workspace_id: "w1", label: "logs", cwd: "/tmp/run-1")

      expect(result.dig("root_pane", "pane_id")).to eq("w1:p3")
    end
  end

  describe ".pane_rename / .tab_rename" do
    it "sends the label for the pane or tab" do
      expect(described_class).to receive(:request!).with("pane.rename", pane_id: "w1:p2", label: "editor")
      expect(described_class).to receive(:request!).with("tab.rename", tab_id: "w1:t1", label: "main")

      described_class.pane_rename("w1:p2", "editor")
      described_class.tab_rename("w1:t1", "main")
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

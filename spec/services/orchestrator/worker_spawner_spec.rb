require "rails_helper"

RSpec.describe Orchestrator::WorkerSpawner do
  describe ".spawn_worker" do
    it "inlines the Claude persona from this repository instead of using a target-workspace agent name" do
      workspace_root = Dir.mktmpdir("workflow-worker-spawner-claude")
      workspace = Workspace.create!(name: "planner-#{SecureRandom.hex(4)}", root_path: workspace_root)
      run = workspace.runs.create!(
        run_id: "demo-#{SecureRandom.hex(4)}",
        task: "Recover a stalled run",
        target_root: workspace.root_path,
        launcher_variant: "claude",
        status: "running",
        launched_by: "operator",
        started_at: Time.current
      )

      spawn_call = nil
      allow(Process).to receive(:spawn) do |*args|
        spawn_call = args
        12_345
      end
      allow(Process).to receive(:detach)

      worker = described_class.spawn_worker(
        run: run,
        role: "planner",
        nickname: "planner-test",
        reason: "Recover the run.",
        scope: "workflow-plan.md",
        prompt: "Inspect the recovery context and publish the next step."
      )

      expect(worker.command).to eq("claude")
      expect(spawn_call[1]).to eq("claude")
      expect(spawn_call[2..]).to include("--permission-mode", "bypassPermissions", "-p", "--")
      expect(spawn_call[2..]).not_to include("--agent", "planner")
      expect(File.read(worker.prompt_path)).to include("# Planner (@planner)")
      expect(File.read(worker.prompt_path)).to include("Current task:\nInspect the recovery context")
    end

    it "inlines the Codex persona from this repository instead of depending on target-workspace agent files" do
      workspace_root = Dir.mktmpdir("workflow-worker-spawner-codex")
      workspace = Workspace.create!(name: "planner-#{SecureRandom.hex(4)}", root_path: workspace_root)
      run = workspace.runs.create!(
        run_id: "demo-#{SecureRandom.hex(4)}",
        task: "Complete the worker handoff",
        target_root: workspace.root_path,
        launcher_variant: "codex",
        status: "running",
        launched_by: "operator",
        started_at: Time.current
      )

      allow(Process).to receive(:spawn).and_return(23_456)
      allow(Process).to receive(:detach)
      stdin_read = instance_double(IO, close: true)
      stdin_write = StringIO.new
      allow(IO).to receive(:pipe).and_return([ stdin_read, stdin_write ])

      worker = described_class.spawn_worker(
        run: run,
        role: "worker",
        nickname: "worker-test",
        reason: "Complete the requested task.",
        scope: "fix-summary.md",
        prompt: "Verify the issue and report back."
      )

      expect(worker.command).to eq("codex")
      expect(File.read(worker.prompt_path)).to include('name = "worker"')
      expect(File.read(worker.prompt_path)).to include("Current task:\nVerify the issue and report back.")
    end
  end
end

require "rails_helper"

RSpec.describe McpTools::CollectArtifactsTool do
  describe ".call" do
    it "returns all artifacts when no filters are applied" do
      run, worker, = create_run_with_artifacts(artifact_names: ["diagnosis.md", "evidence.json"])

      response = described_class.call(runId: run.run_id, server_context: { worker_id: worker.worker_id })

      expect(response.error?).to be_falsey
      data = response.structured_content
      expect(data[:runId]).to eq(run.run_id)
      expect(data[:artifacts].length).to eq(2)
      expect(data[:artifacts].map { |a| a[:name] }).to include("diagnosis.md", "evidence.json")
    end

    it "includes producer information when a worker has produced_artifacts" do
      run, worker, = create_run_with_artifacts(
        artifact_names: ["diagnosis.md", "evidence.json"],
        produced_artifacts: ["diagnosis.md", "evidence.json"]
      )

      response = described_class.call(runId: run.run_id, server_context: { worker_id: worker.worker_id })

      expect(response.error?).to be_falsey
      data = response.structured_content
      diagnosis = data[:artifacts].find { |a| a[:name] == "diagnosis.md" }
      evidence = data[:artifacts].find { |a| a[:name] == "evidence.json" }

      expect(diagnosis[:producedBy]).to eq(worker.worker_id)
      expect(evidence[:producedBy]).to eq(worker.worker_id)
    end

    it "filters artifacts by producer worker_id" do
      run = create_run_with_multiple_workers
      worker1, worker2 = run.workers.order(:created_at).limit(2)

      create_artifacts(run, ["a.md", "b.md"], produced_by: worker1)
      create_artifacts(run, ["c.md", "d.md"], produced_by: worker2)

      response = described_class.call(
        runId: run.run_id,
        producedBy: worker1.worker_id,
        server_context: { worker_id: worker2.worker_id }
      )

      expect(response.error?).to be_falsey
      data = response.structured_content
      expect(data[:artifacts].length).to eq(2)
      expect(data[:artifacts].map { |a| a[:name] }).to match_array(["a.md", "b.md"])
    end

    it "filters artifacts by inheritance status" do
      run, worker, = create_run_with_artifacts(artifact_names: ["inherited.md", "new.md"])

      worker.update!(inherited_artifacts: ["inherited.md"])

      response = described_class.call(
        runId: run.run_id,
        inherited: true,
        server_context: { worker_id: worker.worker_id }
      )

      expect(response.error?).to be_falsey
      data = response.structured_content
      expect(data[:artifacts].length).to eq(1)
      expect(data[:artifacts][0][:name]).to eq("inherited.md")
      expect(data[:artifacts][0][:inherited]).to be_truthy
    end

    it "marks non-inherited artifacts correctly" do
      run, worker, = create_run_with_artifacts(artifact_names: ["new.md"])

      response = described_class.call(
        runId: run.run_id,
        inherited: false,
        server_context: {}
      )

      expect(response.error?).to be_falsey
      data = response.structured_content
      expect(data[:artifacts].length).to eq(1)
      expect(data[:artifacts][0][:inherited]).to be_falsey
    end

    it "includes artifact metadata (size, updated_at, preview)" do
      run, worker, = create_run_with_artifacts(artifact_names: ["file.md"])

      response = described_class.call(runId: run.run_id, server_context: { worker_id: worker.worker_id })

      expect(response.error?).to be_falsey
      data = response.structured_content
      artifact = data[:artifacts].first

      expect(artifact[:name]).to eq("file.md")
      expect(artifact[:exists]).to be_truthy
      expect(artifact[:sizeBytes]).to be_a(Integer)
      expect(artifact[:updatedAt]).to be_a(String)
    end

    it "handles runs with no artifacts gracefully" do
      root = Dir.mktmpdir
      workspace = Workspace.create!(name: "test-#{SecureRandom.hex(4)}", root_path: root)
      run = workspace.runs.create!(
        run_id: "collect-artifacts-empty-#{SecureRandom.hex(4)}", task: "Test",
        target_root: root, launcher_variant: "claude", status: "running"
      )

      response = described_class.call(runId: run.run_id, server_context: {})

      expect(response.error?).to be_falsey
      data = response.structured_content
      expect(data[:artifacts]).to be_empty
    end

    it "includes totalCount in response" do
      run, worker, = create_run_with_artifacts(artifact_names: ["a.md", "b.md", "c.md"])

      response = described_class.call(runId: run.run_id, server_context: { worker_id: worker.worker_id })

      expect(response.error?).to be_falsey
      data = response.structured_content
      expect(data[:totalCount]).to eq(3)
    end

    it "combines multiple filters (producer AND inheritance)" do
      run = create_run_with_multiple_workers
      worker1, worker2 = run.workers.order(:created_at).limit(2)

      create_artifacts(run, ["inherited.md", "new.md"], produced_by: worker1)
      create_artifacts(run, ["other.md"], produced_by: worker2)

      worker2.update!(inherited_artifacts: ["inherited.md"])

      response = described_class.call(
        runId: run.run_id,
        producedBy: worker1.worker_id,
        inherited: true,
        server_context: { worker_id: worker2.worker_id }
      )

      expect(response.error?).to be_falsey
      data = response.structured_content
      expect(data[:artifacts].length).to eq(1)
      expect(data[:artifacts][0][:name]).to eq("inherited.md")
      expect(data[:artifacts][0][:producedBy]).to eq(worker1.worker_id)
    end

    def create_run_with_artifacts(artifact_names:, produced_artifacts: [])
      root = Dir.mktmpdir("collect-artifacts-test")
      workspace = Workspace.create!(name: "collect-artifacts-#{SecureRandom.hex(4)}", root_path: root)
      run = workspace.runs.create!(
        run_id: "collect-artifacts-#{SecureRandom.hex(4)}", task: "Test",
        target_root: root, launcher_variant: "claude", status: "running"
      )

      worker = run.workers.create!(
        worker_id: SecureRandom.uuid,
        role: "worker",
        nickname: "test-worker",
        reason: "test",
        scope: "test.md",
        status: "stopped",
        pid: 99_999,
        command: "claude",
        args: [],
        prompt_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.prompt").to_s,
        log_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.log").to_s,
        last_message_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.last").to_s,
        env_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.env").to_s,
        produced_artifacts: produced_artifacts
      )

      artifact_names.each do |name|
        Orchestrator::ArtifactStore.write(root, run.run_id, name, "test content for #{name}\n" * 10)
      end

      [ run, worker ]
    end

    def create_run_with_multiple_workers
      root = Dir.mktmpdir("collect-artifacts-multi-worker")
      workspace = Workspace.create!(name: "collect-artifacts-multi-#{SecureRandom.hex(4)}", root_path: root)
      run = workspace.runs.create!(
        run_id: "collect-artifacts-multi-#{SecureRandom.hex(4)}", task: "Test",
        target_root: root, launcher_variant: "claude", status: "running"
      )

      2.times do |i|
        run.workers.create!(
          worker_id: SecureRandom.uuid,
          role: "worker",
          nickname: "worker-#{i}",
          reason: "test",
          scope: "test#{i}.md",
          status: "stopped",
          pid: 99_999 + i,
          command: "claude",
          args: [],
          prompt_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.prompt").to_s,
          log_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.log").to_s,
          last_message_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.last").to_s,
          env_path: Rails.root.join("tmp/#{SecureRandom.hex(4)}.env").to_s
        )
      end

      run
    end

    def create_artifacts(run, names, produced_by:)
      names.each do |name|
        Orchestrator::ArtifactStore.write(run.target_root, run.run_id, name, "content for #{name}\n")
      end

      produced_by.update!(produced_artifacts: (produced_by.produced_artifacts || []) + names)
    end
  end
end

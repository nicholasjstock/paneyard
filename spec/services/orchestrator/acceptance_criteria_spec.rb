require "rails_helper"

RSpec.describe Orchestrator::AcceptanceCriteria do
  before do
    workspace = Workspace.create!(name: "criteria-svc-#{SecureRandom.hex(4)}", root_path: Dir.mktmpdir)
    @run = Run.create!(
      workspace:, run_id: "criteria-svc-#{SecureRandom.hex(4)}", task: "Test criteria service",
      target_root: workspace.root_path, launcher_variant: "claude", status: "running"
    )
  end

  describe ".apply!" do
    it "establishes top-level criteria on the first call" do
      described_class.apply!(
        run: @run,
        criteria: [
          { key: "outcome", content: "Demo is faster.", parent_key: nil }
        ],
        updates: []
      )

      criterion = @run.acceptance_criteria.find_by!(key: "outcome")
      assert_nil criterion.parent_id
      assert_equal "pending", criterion.status
    end

    it "rejects a new top-level criterion once the contract already exists" do
      described_class.apply!(run: @run, criteria: [ { key: "outcome", content: "Demo is faster.", parent_key: nil } ], updates: [])

      error = assert_raises(ArgumentError) do
        described_class.apply!(run: @run, criteria: [ { key: "other", content: "Other.", parent_key: nil } ], updates: [])
      end
      assert_includes error.message, "immutable"
    end

    it "decomposes an existing criterion into a child at any later decision" do
      described_class.apply!(run: @run, criteria: [ { key: "outcome", content: "Demo is faster.", parent_key: nil } ], updates: [])

      described_class.apply!(
        run: @run,
        criteria: [ { key: "outcome-sub", content: "Front-end render is faster.", parent_key: "outcome" } ],
        updates: []
      )

      child = @run.acceptance_criteria.find_by!(key: "outcome-sub")
      assert_equal "outcome", child.parent.key
    end

    it "allows decomposing a child into its own grandchild -- depth is unbounded" do
      described_class.apply!(run: @run, criteria: [ { key: "root", content: "Root.", parent_key: nil } ], updates: [])
      described_class.apply!(run: @run, criteria: [ { key: "child", content: "Child.", parent_key: "root" } ], updates: [])
      described_class.apply!(run: @run, criteria: [ { key: "grandchild", content: "Grandchild.", parent_key: "child" } ], updates: [])

      assert_equal "child", @run.acceptance_criteria.find_by!(key: "grandchild").parent.key
    end

    it "rejects a child naming an unknown parent" do
      error = assert_raises(ArgumentError) do
        described_class.apply!(run: @run, criteria: [ { key: "child", content: "Child.", parent_key: "missing" } ], updates: [])
      end
      assert_includes error.message, "Unknown parent"
    end

    it "rejects a duplicate key" do
      described_class.apply!(run: @run, criteria: [ { key: "outcome", content: "Demo is faster.", parent_key: nil } ], updates: [])

      error = assert_raises(ArgumentError) do
        described_class.apply!(run: @run, criteria: [ { key: "outcome", content: "Other.", parent_key: nil } ], updates: [])
      end
      assert_includes error.message, "already exists"
    end
  end

  describe ".apply_update!" do
    before do
      described_class.apply!(run: @run, criteria: [ { key: "outcome", content: "Demo is faster.", parent_key: nil } ], updates: [])
    end

    it "verifies a criterion given a real evidence_ref" do
      Orchestrator::ArtifactStore.write(@run.target_root, @run.run_id, "timings.json", "94.2s")

      described_class.apply!(run: @run, criteria: [], updates: [ { key: "outcome", status: "verified", evidence_ref: "timings.json" } ])

      criterion = @run.acceptance_criteria.find_by!(key: "outcome")
      assert_equal "verified", criterion.status
      assert_equal "timings.json", criterion.evidence_ref
    end

    it "rejects verification without evidence that actually exists" do
      error = assert_raises(ArgumentError) do
        described_class.apply!(run: @run, criteria: [], updates: [ { key: "outcome", status: "verified", evidence_ref: "missing.json" } ])
      end
      assert_match(/evidence/i, error.message)
    end

    it "allows waiving and blocking" do
      described_class.apply!(run: @run, criteria: [], updates: [ { key: "outcome", status: "waived", evidence_ref: nil } ])
      assert_equal "waived", @run.acceptance_criteria.find_by!(key: "outcome").status

      described_class.apply!(run: @run, criteria: [], updates: [ { key: "outcome", status: "blocked", evidence_ref: nil } ])
      assert_equal "blocked", @run.acceptance_criteria.find_by!(key: "outcome").status
    end

    it "raises on an unknown key" do
      assert_raises(ActiveRecord::RecordNotFound) do
        described_class.apply!(run: @run, criteria: [], updates: [ { key: "missing", status: "waived", evidence_ref: nil } ])
      end
    end
  end

  describe ".record_step!" do
    before do
      described_class.apply!(run: @run, criteria: [ { key: "outcome", content: "Demo is faster.", parent_key: nil } ], updates: [])
    end

    it "transitions a pending criterion to in_progress and logs a fulfillment step" do
      described_class.record_step!(
        run: @run,
        next_step: { addresses_criteria: [ "outcome" ], lineage_key: "demo-fix", artifact: "fix.md" }
      )

      criterion = @run.acceptance_criteria.find_by!(key: "outcome")
      assert_equal "in_progress", criterion.status
      assert_equal [ "demo-fix" ], criterion.fulfillment_steps.pluck(:lineage_key)
    end

    it "does not regress a criterion's status once it has moved past pending" do
      described_class.apply!(run: @run, criteria: [], updates: [ { key: "outcome", status: "waived", evidence_ref: nil } ])

      described_class.record_step!(run: @run, next_step: { addresses_criteria: [ "outcome" ], artifact: "fix.md" })

      assert_equal "waived", @run.acceptance_criteria.find_by!(key: "outcome").status
    end

    it "is a no-op for a nil step" do
      assert_nothing_raised { described_class.record_step!(run: @run, next_step: nil) }
    end
  end

  describe ".completion_blockers" do
    it "lists unresolved roots and excludes resolved ones" do
      described_class.apply!(
        run: @run,
        criteria: [
          { key: "a", content: "A.", parent_key: nil },
          { key: "b", content: "B.", parent_key: nil }
        ],
        updates: []
      )
      described_class.apply!(run: @run, criteria: [], updates: [ { key: "a", status: "waived", evidence_ref: nil } ])

      assert_equal [ "b" ], described_class.completion_blockers(run_id: @run.run_id)
    end

    it "treats a root as blocked until every nested child resolves" do
      described_class.apply!(run: @run, criteria: [ { key: "root", content: "Root.", parent_key: nil } ], updates: [])
      described_class.apply!(run: @run, criteria: [ { key: "child", content: "Child.", parent_key: "root" } ], updates: [])

      assert_equal [ "root" ], described_class.completion_blockers(run_id: @run.run_id)

      described_class.apply!(run: @run, criteria: [], updates: [ { key: "child", status: "waived", evidence_ref: nil } ])

      assert_empty described_class.completion_blockers(run_id: @run.run_id)
    end
  end

  describe ".current_keys" do
    it "returns every criterion key, top-level and nested" do
      described_class.apply!(run: @run, criteria: [ { key: "root", content: "Root.", parent_key: nil } ], updates: [])
      described_class.apply!(run: @run, criteria: [ { key: "child", content: "Child.", parent_key: "root" } ], updates: [])

      assert_equal %w[root child].sort, described_class.current_keys(run_id: @run.run_id).sort
    end
  end

  describe ".tree" do
    it "nests children arbitrarily deep with status and resolution" do
      described_class.apply!(run: @run, criteria: [ { key: "root", content: "Root.", parent_key: nil } ], updates: [])
      described_class.apply!(run: @run, criteria: [ { key: "child", content: "Child.", parent_key: "root" } ], updates: [])
      described_class.apply!(run: @run, criteria: [ { key: "grandchild", content: "Grandchild.", parent_key: "child" } ], updates: [])

      tree = described_class.tree(run_id: @run.run_id)

      assert_equal 1, tree.length
      assert_equal "root", tree.first[:key]
      assert_equal false, tree.first[:resolved]
      grandchild = tree.first[:children].first[:children].first
      assert_equal "grandchild", grandchild[:key]
    end
  end
end

require "pathname"

module Orchestrator
  module AcceptanceCriteria
    module_function

    DEMO_INTENT = /\b(demo|video|record(?:ing)?)\b/i
    VIDEO_EXTENSIONS = %w[.mp4 .webm .mov].freeze
    MINIMUM_VIDEO_BYTES = 100_000

    def seed!(run)
      upsert_pending!(
        run:, key: "requested-outcome",
        content: "Deliver and positively verify the requested outcome: #{run.task}"
      )
      if run.task.match?(DEMO_INTENT)
        upsert_pending!(
          run:, key: "demo-artifact",
          content: "Produce a complete, playable demo video in the workspace. Verification requires the video path itself, not a prose report."
        )
      end
      if ObjectiveAlignment.performance_objective?(run.task)
        upsert_pending!(
          run:, key: "measured-performance",
          content: "Record a numeric post-change runtime with units and compare it with the measured baseline."
        )
      end
    end

    def validate_verification!(run_id:, entry_key:, evidence_ref:)
      run = Run.find_by!(run_id:)
      path = workspace_evidence_path(run:, evidence_ref:)
      raise ArgumentError, "Verified acceptance evidence does not exist: #{evidence_ref}" unless path&.file?

      return unless entry_key == "demo-artifact"

      unless VIDEO_EXTENSIONS.include?(path.extname.downcase) && path.size >= MINIMUM_VIDEO_BYTES
        raise ArgumentError, "Demo acceptance requires a video artifact of at least #{MINIMUM_VIDEO_BYTES} bytes"
      end
    end

    def upsert_pending!(run:, key:, content:)
      RunContext.upsert!(
        run_id: run.run_id, entry_key: key, kind: "acceptance_criterion", status: "pending",
        content:, evidence_ref: nil, created_by: "launch"
      )
    end
    private_class_method :upsert_pending!

    def workspace_evidence_path(run:, evidence_ref:)
      reference = evidence_ref.to_s
      return if reference.blank?

      root = Pathname.new(run.target_root).expand_path
      candidate = root.join(reference).cleanpath
      return unless candidate.to_s == root.to_s || candidate.to_s.start_with?("#{root}#{File::SEPARATOR}")

      candidate
    end
    private_class_method :workspace_evidence_path
  end
end

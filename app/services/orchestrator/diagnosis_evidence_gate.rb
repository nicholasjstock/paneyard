module Orchestrator
  module DiagnosisEvidenceGate
    module_function

    OUTCOMES = %w[confirmed blocked].freeze

    def validate!(run_id:, nickname:, scope:, evidence_outcome:, evidence_citations:)
      worker = Worker.find_by(run_id:, nickname:)
      request = diagnosis_request(run_id:, worker:, scope:)
      return unless request

      unless OUTCOMES.include?(evidence_outcome.to_s)
        raise ArgumentError, "diagnosis worker_turn requires evidenceOutcome=confirmed or blocked"
      end

      citations = Array(evidence_citations).map(&:to_s).reject(&:blank?)
      raise ArgumentError, "diagnosis worker_turn requires at least one evidenceCitation" if citations.empty?

      run = Run.find_by!(run_id:)
      artifact = ArtifactStore.read(run.target_root, run_id, scope).force_encoding("UTF-8").scrub
      missing = citations.reject { |citation| artifact.include?(citation) }
      if missing.any?
        raise ArgumentError, "diagnosis evidenceCitation not found in #{scope}: #{missing.join(', ')}"
      end

      ObjectiveAlignment.validate_diagnosis!(run:, request:, artifact:, citations:) if evidence_outcome == "confirmed"
    rescue ObjectiveAlignment::Error => error
      record_alignment_failure!(run:, request:, worker:, error:, evidence_citations: citations)
      raise
    rescue Errno::ENOENT
      raise ArgumentError, "diagnosis worker_turn requires artifact #{scope}"
    end

    def diagnosis_request(run_id:, worker:, scope:)
      requests = SpawnRequest.where(run_id:, scope:, status: "fulfilled").order(created_at: :desc)
      request = if worker
        requests.find_by(fulfilled_worker_id: worker.worker_id)
      else
        requests.first
      end
      request if request&.text.to_s.match?(/\bExecution mode: diagnosis\./i)
    end

    def record_alignment_failure!(run:, request:, worker:, error:, evidence_citations:)
      attempt = StepAttempt.find_or_create_by!(
        run_id: run.run_id, spawn_request: request, worker_id: worker&.worker_id,
        lineage_key: request.lineage_key.presence || request.scope,
        mode: "diagnosis", outcome: "blocked"
      ) do |record|
        record.result = "Objective alignment rejected: #{error.message}"
        record.evidence_outcome = "blocked"
        record.evidence_citations = evidence_citations
      end
      ChaperoneTrigger.call(attempt)
    end
    private_class_method :record_alignment_failure!
  end
end

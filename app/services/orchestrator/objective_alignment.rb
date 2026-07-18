module Orchestrator
  module ObjectiveAlignment
    module_function

    class Error < ArgumentError; end

    PERFORMANCE_INTENT = /\b(slow|slower|fast|faster|speed|performance|latency|duration|timing|throughput|fps)\b/i
    MEASUREMENT = /\b\d+(?:\.\d+)?\s*(?:ms|milliseconds?|s|sec(?:ond)?s?|m|min(?:ute)?s?|fps|frames?\s+per\s+second|%)\b/i

    def performance_objective?(task)
      task.to_s.match?(PERFORMANCE_INTENT)
    end

    def validate_diagnosis!(run:, request:, artifact:, citations:)
      return unless performance_objective?(run.task)

      cited_text = citations.join("\n")
      unless artifact.match?(PERFORMANCE_INTENT) && cited_text.match?(MEASUREMENT)
        reject!(
          run:, request:, artifact:,
          reason: "Performance diagnosis requires a cited numeric baseline with units that measures the original objective."
        )
      end
    end

    def validate_step!(run_id:, step:)
      run = Run.find_by!(run_id:)
      return unless performance_objective?(run.task)
      return if step[:mode].to_s == "diagnosis"

      alignment_text = [ step[:success_check], *Array(step[:evidence_refs]) ].join(" ")
      return if alignment_text.match?(PERFORMANCE_INTENT)

      raise ArgumentError, "step does not retain the run's performance objective"
    end

    def reject!(run:, request:, artifact:, reason:)
      RunContext.upsert!(
        run_id: run.run_id,
        entry_key: "rejected-diagnosis-#{request.lineage_key.presence || request.scope}",
        kind: "rejected_approach", status: "rejected",
        content: "#{reason} Preserve this finding as a separate candidate; do not replace the run objective. Artifact excerpt: #{artifact.first(800)}",
        evidence_ref: request.scope, created_by: "objective_alignment"
      )
      raise Error, reason
    end
    private_class_method :reject!
  end
end

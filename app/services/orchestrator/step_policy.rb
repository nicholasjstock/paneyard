module Orchestrator
  module StepPolicy
    module_function

    MODES = %w[diagnosis implementation verification recording infrastructure].freeze
    WRITE_SCOPES = %w[artifact_only tests_only scoped_changes].freeze
    EXECUTOR_OWNERS = %w[worker infrastructure planner].freeze
    PLANNER_STEP_OWNERS = %w[worker infrastructure].freeze
    PROTECTED_PATH_PATTERNS = [
      %r{(^|/)controllers?(/|$)},
      %r{(^|/)db/migrate(/|$)},
      %r{(^|/)(schema\.(rb|sql)|structure\.sql)$},
      %r{(^|/)generated(/|$)},
      %r{(^|/)openapi\.(ya?ml|json)$}
    ].freeze
    IMPLEMENTATION_LANGUAGE = /\b(implement|fix|patch|modify|edit|change|land|ship)\b/i
    NEGATED_IMPLEMENTATION_LANGUAGE = /\b(do not|don't|never)\b(?:\s+\w+){0,3}\s+(implement|fix|patch|modify|edit|change|land|ship)\b/i

    def validate_plan!(run_id:, next_step:, following_steps:)
      validate!(run_id: run_id, step: next_step) if next_step
      Array(following_steps).each { |step| validate!(run_id: run_id, step: step) }
    end

    # Remove authority that a non-writing step cannot use. This repair can
    # only narrow access; implementation paths are never inferred here.
    def normalize_plan(next_step:, following_steps:)
      {
        next_step: normalize_step(next_step),
        following_steps: Array(following_steps).map { |step| normalize_step(step) }
      }
    end

    def normalize_step(step)
      return unless step

      normalized = step.deep_dup
      if normalized[:mode].to_s.in?(%w[verification recording]) ||
          (normalized[:mode].to_s == "diagnosis" && normalized[:write_scope].to_s == "artifact_only")
        normalized[:allowed_paths] = []
      end
      normalized
    end
    private_class_method :normalize_step

    def validate!(run_id:, step:)
      owner = step[:owner].to_s
      mode = step[:mode].to_s
      write_scope = step[:write_scope].to_s
      allowed_paths = Array(step[:allowed_paths]).map(&:to_s)
      evidence_refs = Array(step[:evidence_refs]).map(&:to_s).reject(&:blank?)

      raise ArgumentError, "Planner step must name an executable owner" unless EXECUTOR_OWNERS.include?(owner)
      raise ArgumentError, "Planner step must declare mode" unless MODES.include?(mode)
      raise ArgumentError, "Planner step must declare writeScope" unless WRITE_SCOPES.include?(write_scope)
      reject_ambiguous_paths!(allowed_paths)

      case mode
      when "diagnosis"
        validate_diagnosis!(step:, write_scope:, allowed_paths:)
      when "implementation", "infrastructure"
        raise ArgumentError, "#{mode} step requires at least one evidenceRef" if evidence_refs.empty?
        raise ArgumentError, "#{mode} step requires exact allowedPaths" if allowed_paths.empty?
        raise ArgumentError, "#{mode} step requires writeScope=scoped_changes" unless write_scope == "scoped_changes"
      when "verification", "recording"
        raise ArgumentError, "#{mode} step must use writeScope=artifact_only" unless write_scope == "artifact_only"
        raise ArgumentError, "#{mode} step cannot authorize repository paths" if allowed_paths.any?
      end

      require_operator_approval!(run_id:, step:, allowed_paths:)
      ObjectiveAlignment.validate_step!(run_id:, step:)
      step
    end

    def worker_instructions(step)
      lines = [
        "Execution mode: #{step[:mode]}.",
        "Write scope: #{step[:write_scope]}.",
        "Allowed repository paths: #{Array(step[:allowed_paths]).presence&.join(', ') || 'none'}.",
        "Evidence references: #{Array(step[:evidence_refs]).presence&.join(', ') || 'none'}.",
        step[:success_check]
      ]
      if step[:mode] == "diagnosis"
        lines << "This is an evidence-gathering task. Do not implement an application fix or change a public contract. Report the confirmed boundary back to the planner."
        lines << "Before worker_turn, write the artifact and pass evidenceOutcome=confirmed or blocked plus evidenceCitations copied verbatim from that artifact. Use blocked when the reproduction did not reach the target boundary."
      end
      unless step[:operator_approval_question_id].present?
        lines << "No operator approval exists for controller, OpenAPI, migration, schema, or generated-file changes."
      end
      lines.join(" ")
    end

    def validate_diagnosis!(step:, write_scope:, allowed_paths:)
      if diagnosis_requests_implementation?(step[:success_check].to_s)
        raise ArgumentError, "diagnosis step cannot also request implementation"
      end
      unless write_scope.in?(%w[artifact_only tests_only])
        raise ArgumentError, "diagnosis step must use artifact_only or tests_only write scope"
      end
      if write_scope == "artifact_only" && allowed_paths.any?
        raise ArgumentError, "artifact-only diagnosis cannot authorize repository paths"
      end
      return unless write_scope == "tests_only"

      invalid = allowed_paths.reject { |path| diagnostic_path?(path) }
      raise ArgumentError, "diagnosis may write only test or diagnostic paths: #{invalid.join(', ')}" if invalid.any?
    end

    def diagnosis_requests_implementation?(success_check)
      success_check.match?(IMPLEMENTATION_LANGUAGE) &&
        !success_check.match?(NEGATED_IMPLEMENTATION_LANGUAGE)
    end

    def diagnostic_path?(path)
      path.match?(%r{(^|/)(spec|test|tests|__tests__)(/|$)}) ||
        path.start_with?("tmp/", "scripts/diagnostics/")
    end

    def reject_ambiguous_paths!(paths)
      ambiguous = paths.select { |path| path.blank? || path.end_with?("/") || path.match?(/[\*\?\[\]\{\}]/) }
      raise ArgumentError, "allowedPaths must name exact files: #{ambiguous.join(', ')}" if ambiguous.any?
    end

    def require_operator_approval!(run_id:, step:, allowed_paths:)
      protected_paths = allowed_paths.select { |path| PROTECTED_PATH_PATTERNS.any? { |pattern| path.match?(pattern) } }
      return if protected_paths.empty?

      question_id = step[:operator_approval_question_id].presence
      question = question_id && UserQuestion.find_by(question_id:, run_id:, status: "answered")
      unless question&.answer_text.present?
        raise ArgumentError, "Protected paths require an answered operator question: #{protected_paths.join(', ')}"
      end
    end
  end
end

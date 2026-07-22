module Orchestrator
  module StepPolicy
    module_function

    MODES = %w[diagnosis implementation verification recording infrastructure].freeze
    WRITE_SCOPES = %w[source_protected tests_only scoped_changes].freeze
    EXECUTOR_OWNERS = %w[worker infrastructure planner].freeze
    PLANNER_STEP_OWNERS = %w[worker infrastructure].freeze
    IMPLEMENTATION_LANGUAGE = /\b(implement|fix|patch|modify|edit|change|land|ship)\b/i
    NEGATED_IMPLEMENTATION_LANGUAGE = /\b(do not|don't|never)\b(?:\s+\w+){0,3}\s+(implement|fix|patch|modify|edit|change|land|ship)\b/i

    def validate_plan!(run_id:, next_step:, following_steps:, acceptance_criteria_keys: nil)
      keys = acceptance_criteria_keys || current_acceptance_criteria_keys(run_id)
      validate!(run_id: run_id, step: next_step, acceptance_criteria_keys: keys) if next_step
      Array(following_steps).each { |step| validate!(run_id: run_id, step: step, acceptance_criteria_keys: keys) }
    end

    def current_acceptance_criteria_keys(run_id)
      Orchestrator::AcceptanceCriteria.current_keys(run_id: run_id)
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
          (normalized[:mode].to_s == "diagnosis" && normalized[:write_scope].to_s == "source_protected")
        normalized[:allowed_paths] = []
      end
      normalized
    end
    private_class_method :normalize_step

    def validate!(run_id:, step:, acceptance_criteria_keys: nil)
      owner = step[:owner].to_s
      mode = step[:mode].to_s
      write_scope = step[:write_scope].to_s
      allowed_paths = Array(step[:allowed_paths]).map(&:to_s)
      evidence_refs = Array(step[:evidence_refs]).map(&:to_s).reject(&:blank?)

      raise ArgumentError, "Planner step must name an executable owner" unless EXECUTOR_OWNERS.include?(owner)
      validate_artifact_name!(step[:artifact])
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
        raise ArgumentError, "#{mode} step must use writeScope=source_protected" unless write_scope == "source_protected"
        raise ArgumentError, "#{mode} step cannot authorize repository paths" if allowed_paths.any?
      end

      keys = acceptance_criteria_keys || current_acceptance_criteria_keys(run_id)
      require_acceptance_criteria_reference!(step:, acceptance_criteria_keys: keys)
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
      lines.join(" ")
    end

    def validate_diagnosis!(step:, write_scope:, allowed_paths:)
      if diagnosis_requests_implementation?(step[:success_check].to_s)
        raise ArgumentError, "diagnosis step cannot also request implementation"
      end
      unless write_scope.in?(%w[source_protected tests_only])
        raise ArgumentError, "diagnosis step must use source_protected or tests_only write scope"
      end
      if write_scope == "source_protected" && allowed_paths.any?
        raise ArgumentError, "source-protected diagnosis cannot authorize repository paths"
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

    # ArtifactStore always places a run artifact beneath its managed output
    # directory. Accepting a path here would therefore be both redundant and
    # unsafe, and would fail only after a worker had already been dispatched.
    # Reject it during planner submission so the model receives accepted=false
    # and can repair the same decision turn.
    def validate_artifact_name!(artifact)
      name = artifact.to_s
      if name.blank? || name == "." || name == ".." || name.include?("/") || name.include?("\\") || name.include?("\0")
        raise ArgumentError, "artifact must be a filename only, without a path prefix: #{artifact.inspect}"
      end
    end
    private_class_method :validate_artifact_name!

    # Structural, not semantic: the step must name real, current acceptance
    # criteria keys (top-level or nested children) -- Rails never tries to
    # judge whether the step's prose "relates to" an objective by matching
    # text. Empty acceptance_criteria_keys is a bootstrap exemption: nothing
    # has been established yet to drift from (e.g. the very first decision's
    # own Rails-generated fallback step, or a run whose contract genuinely
    # doesn't exist yet).
    def require_acceptance_criteria_reference!(step:, acceptance_criteria_keys:)
      return if acceptance_criteria_keys.empty?

      addresses = Array(step[:addresses_criteria]).map(&:to_s).reject(&:blank?)
      raise ArgumentError, "Planner step must name which acceptance criteria it addresses (addressesCriteria)" if addresses.empty?

      unknown = addresses - acceptance_criteria_keys
      raise ArgumentError, "addressesCriteria names unknown criteria: #{unknown.join(', ')}" if unknown.any?
    end
  end
end

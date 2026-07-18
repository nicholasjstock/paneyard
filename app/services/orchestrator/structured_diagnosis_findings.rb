require "pathname"

module Orchestrator
  module StructuredDiagnosisFindings
    module_function

    MAX_TARGET_PATHS = 12
    MAX_MEASUREMENTS = 12

    def persist!(run_id:, nickname:, scope:, findings:)
      return if findings.blank?

      run = Run.find_by!(run_id:)
      artifact = ArtifactStore.read(run.target_root, run_id, scope).force_encoding("UTF-8").scrub
      target_paths = validate_paths!(run.target_root, artifact, Array(findings[:target_paths]))
      measurements = validate_measurements!(Array(findings[:measurements]))
      objective = findings[:objective].to_s.strip.presence

      payload = { target_paths:, measurements:, objective: }.compact
      raise ArgumentError, "diagnosisFindings must contain a target path, measurement, or objective" if payload.values.all?(&:blank?)

      request = DiagnosisEvidenceGate.diagnosis_request(
        run_id:, worker: Worker.where(run_id:, nickname:).order(created_at: :desc).first, scope:
      )
      lineage = request&.lineage_key.presence || scope
      RunContext.upsert!(
        run_id:, entry_key: "diagnosis-findings-#{lineage.gsub(/[^A-Za-z0-9._-]/, "_")}",
        kind: "fact", status: "confirmed", content: JSON.generate(payload),
        evidence_ref: scope, created_by: nickname
      )
    rescue Errno::ENOENT
      raise ArgumentError, "diagnosisFindings require artifact #{scope}"
    end

    def validate_paths!(root, artifact, paths)
      raise ArgumentError, "diagnosisFindings accepts at most #{MAX_TARGET_PATHS} targetPaths" if paths.length > MAX_TARGET_PATHS

      root_path = Pathname.new(root).realpath
      paths.map do |path|
        value = path.to_s.strip
        candidate = root_path.join(value).cleanpath
        unless value.present? && !Pathname.new(value).absolute? &&
            candidate.to_s.start_with?("#{root_path}#{File::SEPARATOR}") &&
            !value.end_with?("/") && !value.match?(/[\*\?\[\]\{\}]/)
          raise ArgumentError, "diagnosis targetPath must be one exact workspace-relative file: #{value}"
        end
        raise ArgumentError, "diagnosis targetPath is not cited in #{File.basename(value)} artifact" unless artifact.include?(value)

        value
      end.uniq
    end
    private_class_method :validate_paths!

    def validate_measurements!(measurements)
      raise ArgumentError, "diagnosisFindings accepts at most #{MAX_MEASUREMENTS} measurements" if measurements.length > MAX_MEASUREMENTS

      measurements.map do |measurement|
        name = measurement[:name].to_s.strip
        value = Float(measurement[:value])
        unit = measurement[:unit].to_s.strip
        unless name.present? && unit.present? && value.finite?
          raise ArgumentError, "diagnosis measurement requires a finite value, name, and unit"
        end

        { name:, value:, unit: }
      rescue ArgumentError, TypeError
        raise ArgumentError, "diagnosis measurement requires a finite numeric value, name, and unit"
      end
    end
    private_class_method :validate_measurements!
  end
end

module Orchestrator
  # Ports scripts/workflow-mcp.ts's writeWorkflowArtifact/readWorkflowArtifact/
  # collectWorkflowState/resolveWorkflowArtifactPath/sanitizeRunId. Artifact
  # files are explicitly out of scope for the JSON-bus-to-Rails migration
  # (free-form content, not structured bus state) -- they stay as local
  # files on the workspace's own filesystem, same as before.
  module ArtifactStore
    module_function

    def output_dir(root_dir)
      File.join(root_dir, "front", "demo-output", "agents-sdk")
    end

    def sanitize_run_id(run_id)
      sanitized = run_id.to_s.strip.gsub(/[^A-Za-z0-9._-]/, "_")
      raise ArgumentError, "run_id must not be empty" if sanitized.empty?

      sanitized
    end

    def resolve_path(root_dir, run_id, artifact_name)
      if artifact_name.blank? || artifact_name == "." || artifact_name == ".." ||
         artifact_name.include?("/") || artifact_name.include?("\\") || artifact_name.include?("\0")
        raise ArgumentError, "Unsafe workflow artifact name: #{artifact_name}"
      end

      File.join(output_dir(root_dir), sanitize_run_id(run_id), artifact_name)
    end

    def write(root_dir, run_id, artifact_name, content)
      path = resolve_path(root_dir, run_id, artifact_name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      path
    end

    def read(root_dir, run_id, artifact_name)
      File.read(resolve_path(root_dir, run_id, artifact_name))
    end

    def collect(root_dir, run_id, artifact_names)
      artifacts = artifact_names.map do |name|
        path = resolve_path(root_dir, run_id, name)

        unless File.exist?(path)
          next { name: name, path: path, exists: false, size_bytes: nil, updated_at: nil, preview: nil }
        end

        stat = File.stat(path)
        preview = File.open(path, "rb") { |f| f.read(200) }
        {
          name: name, path: path, exists: true, size_bytes: stat.size,
          updated_at: stat.mtime.utc.iso8601(3), preview: preview&.scrub
        }
      end

      { output_dir: output_dir(root_dir), artifacts: artifacts }
    end
  end
end

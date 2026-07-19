require "pathname"

module Orchestrator
  # Ports scripts/workflow-mcp.ts's writeWorkflowArtifact/readWorkflowArtifact/
  # collectWorkflowState/resolveWorkflowArtifactPath/sanitizeRunId. Artifact
  # files are explicitly out of scope for the JSON-bus-to-Rails migration
  # (free-form content, not structured bus state) -- they stay as local
  # files on the workspace's own filesystem, same as before.
  module ArtifactStore
    module_function

    DEFAULT_READ_LIMIT = 2_000
    MAX_READ_LIMIT = 8_000
    DEFAULT_OUTPUT_DIR = File.join(".workflow-orchestrator", "artifacts")
    LEGACY_OUTPUT_DIR = File.join("front", "demo-output", "agents-sdk")

    def output_dir(root_dir)
      generic = File.join(root_dir, DEFAULT_OUTPUT_DIR)
      legacy = File.join(root_dir, LEGACY_OUTPUT_DIR)
      return legacy if !Dir.exist?(generic) && Dir.exist?(legacy)

      generic
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

    def canonical_name(root_dir, run_id, reference)
      value = reference.to_s
      run_dir = File.join(output_dir(root_dir), sanitize_run_id(run_id))
      absolute = Pathname.new(value).absolute? ? File.expand_path(value) : File.expand_path(value, root_dir)
      return value unless File.dirname(absolute) == File.expand_path(run_dir)

      File.basename(absolute)
    end

    def write(root_dir, run_id, artifact_name, content)
      path = resolve_path(root_dir, run_id, artifact_name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      path
    end

    def names(root_dir, run_id)
      run_dir = File.join(output_dir(root_dir), sanitize_run_id(run_id))
      return [] unless Dir.exist?(run_dir)

      Dir.children(run_dir).select { |name| File.file?(File.join(run_dir, name)) }.sort
    end

    def read(root_dir, run_id, artifact_name)
      File.read(resolve_path(root_dir, run_id, artifact_name))
    end

    # MCP consumers should start with a small evidence window and request a
    # later offset only when that window leaves a specific question open.
    # Offsets are bytes so they can be used directly with File#seek.
    def read_window(root_dir, run_id, artifact_name, offset: 0, limit: DEFAULT_READ_LIMIT)
      path = resolve_path(root_dir, run_id, artifact_name)
      total_bytes = File.size(path)
      start_offset = offset.to_i.clamp(0, total_bytes)
      byte_limit = limit.to_i.clamp(1, MAX_READ_LIMIT)
      content = File.binread(path, byte_limit, start_offset).force_encoding("UTF-8").scrub
      next_offset = start_offset + content.bytesize

      {
        content: content,
        total_bytes: total_bytes,
        offset: start_offset,
        next_offset: next_offset < total_bytes ? next_offset : nil,
        truncated: next_offset < total_bytes
      }
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

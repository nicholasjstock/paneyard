require "pathname"

module Orchestrator
  module PlannerContextResolver
    module_function

    SOURCES = %w[artifact run_context worker_log file].freeze

    def resolve(run:, context_request:)
      source = context_request.fetch(:source)
      reference = context_request.fetch(:reference)
      offset = context_request.fetch(:offset, 0).to_i
      max_chars = context_request.fetch(:max_chars).to_i
      raise ArgumentError, "Unsupported planner context source: #{source}" unless SOURCES.include?(source)
      raise ArgumentError, "Planner context maxChars must be positive" unless max_chars.positive?

      resolved = case source
      when "artifact"
        reference = ArtifactStore.canonical_name(run.target_root, run.run_id, reference)
        path = ArtifactStore.resolve_path(run.target_root, run.run_id, reference)
        read_file_window(path, offset:, max_chars:)
      when "run_context"
        snapshot = RunContext.snapshot(run_id: run.run_id, entry_keys: [ reference ])
        content = JSON.pretty_generate(snapshot)
        { content: content.first(max_chars), truncated: content.length > max_chars, available: snapshot[:entries].present? }
      when "worker_log"
        worker = run.workers.find_by(nickname: reference) || raise(ArgumentError, "Unknown worker: #{reference}")
        content = LogReader.read_tail_lines(worker.log_path, 80).to_s
        { content: content.last(max_chars), truncated: content.length > max_chars, available: content.present? }
      when "file"
        read_workspace_file(run.target_root, reference, offset:, max_chars:)
      end

      {
        source: source,
        reference: reference,
        offset: offset,
        max_chars: max_chars,
        next_offset: resolved[:next_offset],
        truncated: resolved[:truncated] || false,
        question: context_request.fetch(:question),
        content: resolved[:content].to_s,
        returned_bytes: resolved[:content].to_s.bytesize,
        available: resolved.fetch(:available, resolved[:content].present?)
      }
    rescue Errno::ENOENT
      missing = "Requested context does not exist."
      {
        source: source, reference: reference, offset: offset, max_chars: max_chars,
        next_offset: nil, truncated: false, question: context_request.fetch(:question),
        content: missing, returned_bytes: missing.bytesize, available: false
      }
    end

    def read_workspace_file(root, reference, offset:, max_chars:)
      root_path = Pathname.new(root).realpath
      candidate = root_path.join(reference).cleanpath
      unless candidate.to_s.start_with?("#{root_path}#{File::SEPARATOR}")
        raise ArgumentError, "Planner context file must stay inside the workspace"
      end

      read_file_window(candidate, offset:, max_chars:)
    end
    private_class_method :read_workspace_file

    def read_file_window(path, offset:, max_chars:)
      total_bytes = File.size(path)
      start_offset = offset.clamp(0, total_bytes)
      content = File.binread(path, max_chars, start_offset).force_encoding("UTF-8").scrub
      next_offset = start_offset + content.bytesize
      { content:, next_offset: next_offset < total_bytes ? next_offset : nil, truncated: next_offset < total_bytes, available: true }
    end
    private_class_method :read_file_window
  end
end

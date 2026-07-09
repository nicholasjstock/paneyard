module Orchestrator
  # Ruby port of scripts/workflow-log-reader.ts's bounded tail-reading
  # algorithm (same truncation/tail-line semantics), used once
  # WorkersController#show reads log_path directly off the local
  # filesystem (same host as the supervisor loop) instead of proxying the
  # read through Node.
  module LogReader
    module_function

    # @return [Hash] { content:, truncated:, total_bytes: }
    def read_full_content(path, max_chars)
      return { content: nil, truncated: false, total_bytes: 0 } unless File.exist?(path)

      total_bytes = File.size(path)
      content = File.read(path)

      return { content: content, truncated: false, total_bytes: total_bytes } if content.length <= max_chars

      raw_slice = content[(content.length - max_chars)..]
      first_newline = raw_slice.index("\n")
      trimmed_slice = first_newline.nil? ? raw_slice : raw_slice[(first_newline + 1)..]

      { content: trimmed_slice, truncated: true, total_bytes: total_bytes }
    end

    def read_tail_lines(path, line_count)
      return nil unless File.exist?(path)

      contents = File.read(path)
      lines = contents.sub(/\r?\n\z/, "").split(/\r?\n/)
      tail = lines.last([ line_count, 0 ].max).reject(&:empty?)

      tail.empty? ? nil : "#{tail.join("\n")}\n"
    end
  end
end

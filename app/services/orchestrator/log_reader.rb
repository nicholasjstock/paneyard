module Orchestrator
  # Ruby port of scripts/workflow-log-reader.ts's bounded tail-reading
  # algorithm (same truncation/tail-line semantics), used once
  # WorkersController#show reads log_path directly off the local
  # filesystem (same host as the supervisor loop) instead of proxying the
  # read through Node.
  module LogReader
    module_function

    # @return [Hash] { content:, truncated:, total_bytes: }
    def read_full_content(path, max_chars = nil)
      return { content: nil, truncated: false, total_bytes: 0 } unless File.exist?(path)

      total_bytes = File.size(path)
      content = File.read(path)

      return { content: content, truncated: false, total_bytes: total_bytes } if max_chars.nil? || content.length <= max_chars

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

    # Claude's final stream-json `result` event carries aggregate usage for
    # the whole agent session. Read only the tail because that event is
    # emitted at the end, after all incremental messages.
    def claude_usage(path)
      read_tail_lines(path, 100).to_s.each_line.to_a.reverse_each do |line|
        event = JSON.parse(line)
        next unless event["type"] == "result"

        usage = event["usage"] || {}
        return {
          model: event["model"],
          agent_turn_count: event["num_turns"],
          input_tokens: usage["input_tokens"],
          output_tokens: usage["output_tokens"],
          cache_read_input_tokens: usage["cache_read_input_tokens"],
          cache_creation_input_tokens: usage["cache_creation_input_tokens"],
          total_cost_usd: event["total_cost_usd"]
        }.compact
      rescue JSON::ParserError
        next
      end

      {}
    end

    # Claude's stream-json protocol is useful for transport but unreadable in
    # an operations UI. Collapse it into the assistant text and completed
    # tool calls while leaving non-protocol lines, such as lifecycle events,
    # visible verbatim.
    def format_for_display(content)
      return content if content.blank?

      output = []
      text_buffers = Hash.new { |hash, key| hash[key] = String.new }
      tool_calls = {}

      content.each_line do |line|
        event = JSON.parse(line)
        format_json_event(event, output, text_buffers, tool_calls)
      rescue JSON::ParserError
        output << line.chomp unless line.strip.empty?
      end

      output.concat(text_buffers.values.reject(&:blank?))
      output.join("\n")
    end

    def format_json_event(event, output, text_buffers, tool_calls)
      stream_event = event["event"] if event["type"] == "stream_event"
      return format_system_event(event, output) unless stream_event

      index = stream_event["index"]
      case stream_event["type"]
      when "content_block_start"
        block = stream_event["content_block"] || {}
        text_buffers[index] = String.new if block["type"] == "text"
        tool_calls[index] = { name: block["name"], input: String.new } if block["type"] == "tool_use"
      when "content_block_delta"
        delta = stream_event["delta"] || {}
        text_buffers[index] << delta["text"].to_s if delta["type"] == "text_delta"
        tool_calls[index][:input] << delta["partial_json"].to_s if delta["type"] == "input_json_delta" && tool_calls[index]
      when "content_block_stop"
        output << text_buffers.delete(index).to_s.strip if text_buffers[index].present?
        tool_call = tool_calls.delete(index)
        output << format_tool_call(tool_call) if tool_call
      end
    end

    def format_system_event(event, output)
      return unless event["type"] == "system" && event["subtype"] == "error"

      output << "[system error] #{event["error"].presence || event["message"].presence || "unknown error"}"
    end

    def format_tool_call(tool_call)
      input = JSON.parse(tool_call[:input])
      return "$ #{input["command"]}" if tool_call[:name] == "Bash" && input["command"].present?

      details = input.slice("file_path", "path", "artifactName", "runId").compact
      suffix = details.map { |key, value| "#{key}=#{value}" }.join(" ")
      "[tool] #{tool_call[:name]}#{" #{suffix}" if suffix.present?}"
    rescue JSON::ParserError
      "[tool] #{tool_call[:name]}"
    end
  end
end

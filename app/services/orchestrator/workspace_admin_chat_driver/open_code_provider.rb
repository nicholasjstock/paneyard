require "json"

module Orchestrator
  module WorkspaceAdminChatDriver
    module OpenCodeProvider
      module_function

      DEFAULT_MODEL = "ollama/qwen2.5-coder:14b"

      SESSION_MISSING_PATTERN = /session not found/i

      def run_turn(workspace_path:, prompt:, session_id:, model:, on_spawn: nil, &on_event)
        args = build_args(session_id:, model: model.presence || DEFAULT_MODEL, prompt:)
        env = SessionEnv.sanitized_process_env
        new_session_id = session_id

        result = ProcessStream.run(env:, args:, chdir: workspace_path, on_spawn:) do |line|
          line = line.strip
          next if line.empty?

          envelope = parse_line(line, &on_event)
          next unless envelope

          handle_event(envelope) do |normalized|
            new_session_id = normalized[:session_id] if normalized[:type] == "session_started"
            on_event.call(normalized)
          end
        end

        report_process_error(result, &on_event)
        { session_id: new_session_id, cancelled: cancelled?(result), error: turn_errored?(result), stderr: result[:stderr] }
      end

      def session_missing?(stderr)
        stderr.to_s.match?(SESSION_MISSING_PATTERN)
      end

      def build_args(session_id:, model:, prompt:)
        args = %w[opencode run --format json --auto]
        args += [ "-s", session_id ] if session_id.present?
        args += [ "-m", model ]
        args << prompt
        args
      end

      def parse_line(line)
        JSON.parse(line)
      rescue JSON::ParserError
        yield({ type: "error", message: "opencode emitted malformed JSON", detail: line.byteslice(0, 500) })
        nil
      end

      def handle_event(envelope)
        case envelope["type"]
        when "step_start"
          session_id = envelope["sessionID"]
          yield({ type: "session_started", session_id: }) if session_id.present?

          part = envelope["part"]
          if part.is_a?(Hash)
            yield({ type: "tool_started", id: part["id"], name: "step", detail: part }) if part["type"] == "tool-start"
          end
        when "text"
          yield({ type: "assistant_delta", text: envelope.dig("part", "text") })
        when "tool_start"
          part = envelope["part"] || {}
          yield({ type: "tool_started", id: part["id"] || envelope["id"], name: part["name"] || "tool", detail: part })
        when "tool_finish"
          part = envelope["part"] || {}
          yield({ type: "tool_completed", id: part["id"] || envelope["id"], result: part })
          path = part.dig("input", "file_path") || part.dig("file_path")
          yield({ type: "file_changed", path: }) if path.present?
        when "step_finish"
          yield({ type: "assistant_completed", text: envelope.dig("part", "text") })
          yield({ type: "turn_completed", usage: usage_from(envelope) })
        when "error"
          error = envelope["error"] || {}
          yield({ type: "error", message: error["message"] || error["name"] || "opencode turn failed", detail: error })
        end
      end

      def usage_from(envelope)
        part = envelope["part"] || {}
        tokens = part["tokens"] || {}
        {
          "input_tokens" => tokens["input"],
          "output_tokens" => tokens["output"],
          "reasoning_tokens" => tokens["reasoning"],
          "cache_write_tokens" => tokens.dig("cache", "write"),
          "cache_read_tokens" => tokens.dig("cache", "read"),
          "total_cost_usd" => part["cost"]
        }.compact
      end

      def cancelled?(result)
        result[:status]&.signaled? || false
      end

      def turn_errored?(result)
        !cancelled?(result) && !result[:status]&.success?
      end

      def report_process_error(result)
        return unless turn_errored?(result)

        yield({ type: "error", message: "opencode exited #{result[:status]&.exitstatus}", detail: result[:stderr].presence })
      end
    end
  end
end

require "json"

module Orchestrator
  module WorkspaceAdminChatDriver
    # Runs one non-interactive `claude -p` turn and normalizes its
    # `--output-format stream-json` lines into WorkspaceAdminChatEvent hashes
    # (see the WorkspaceChatEvent union in the feature spec this ports).
    # bypassPermissions matches TerminalSessionRunner's own rationale: this
    # runs with nobody present to answer an interactive permission prompt, so
    # "dontAsk" (which silently denies instead) would make the CLI quietly
    # skip actions the operator asked for.
    module ClaudeProvider
      module_function

      DEFAULT_MODEL = "sonnet"
      PERMISSION_MODE = "bypassPermissions"

      # The exact, stable one-line message claude -p prints to stderr for a
      # --resume id it no longer has on disk (confirmed directly: `claude -p
      # --resume <made-up-uuid> ...` exits 1 with exactly this line, nothing
      # on stdout, no silent fallback to a fresh session). Runner uses this
      # to distinguish "the session is actually gone" from an ordinary
      # failure (rate limit, network error, ...), which should just fail the
      # turn rather than triggering a reconstruction retry.
      SESSION_MISSING_PATTERN = /No conversation found with session ID/i

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
        args = [
          "claude", "-p",
          "--output-format", "stream-json", "--verbose", "--include-partial-messages",
          "--model", model,
          "--permission-mode", PERMISSION_MODE
        ]
        args += [ "--resume", session_id ] if session_id.present?
        args << prompt
        args
      end

      def parse_line(line)
        JSON.parse(line)
      rescue JSON::ParserError
        yield({ type: "error", message: "claude emitted malformed JSON", detail: line.byteslice(0, 500) })
        nil
      end

      def handle_event(envelope)
        case envelope["type"]
        when "system"
          yield({ type: "session_started", session_id: envelope["session_id"] }) if envelope["subtype"] == "init" && envelope["session_id"].present?
        when "stream_event"
          handle_stream_event(envelope["event"]) { |e| yield e }
        when "assistant"
          handle_assistant_message(envelope["message"]) { |e| yield e }
        when "user"
          handle_tool_results(envelope["message"]) { |e| yield e }
        when "result"
          handle_result(envelope) { |e| yield e }
        end
      end

      def handle_stream_event(event)
        return unless event.is_a?(Hash) && event["type"] == "content_block_delta"

        text = event.dig("delta", "text")
        yield({ type: "assistant_delta", text: }) if text.present?
      end

      def handle_assistant_message(message)
        return unless message.is_a?(Hash)

        Array(message["content"]).each do |block|
          next unless block.is_a?(Hash) && block["type"] == "tool_use"

          yield({ type: "tool_started", id: block["id"], name: block["name"], detail: block["input"] })
          path = block.dig("input", "file_path")
          yield({ type: "file_changed", path: }) if block["name"].in?(%w[Edit Write]) && path.present?
        end
      end

      def handle_tool_results(message)
        return unless message.is_a?(Hash)

        Array(message["content"]).each do |block|
          next unless block.is_a?(Hash) && block["type"] == "tool_result"

          yield({ type: "tool_completed", id: block["tool_use_id"], result: block["content"] })
        end
      end

      def handle_result(envelope)
        yield({ type: "assistant_completed", text: envelope["result"].to_s }) if envelope["result"].present?
        yield({ type: "error", message: envelope["result"].to_s }) if envelope["is_error"]
        yield({ type: "turn_completed", usage: usage_from(envelope) })
      end

      def usage_from(envelope)
        usage = envelope["usage"] || {}
        {
          "input_tokens" => usage["input_tokens"], "output_tokens" => usage["output_tokens"],
          "cache_read_input_tokens" => usage["cache_read_input_tokens"], "total_cost_usd" => envelope["total_cost_usd"]
        }.compact
      end

      # A kill sent from Runner#cancel_turn! (possibly in a different OS
      # process -- see ProcessStream's module comment) ends this turn via a
      # signal, not a plain nonzero exit -- that's how a cancel is
      # distinguished from an ordinary CLI failure after the fact.
      def cancelled?(result)
        result[:status]&.signaled? || false
      end

      def turn_errored?(result)
        !cancelled?(result) && !result[:status]&.success?
      end

      def report_process_error(result)
        return unless turn_errored?(result)

        yield({ type: "error", message: "claude exited #{result[:status]&.exitstatus}", detail: result[:stderr].presence })
      end
    end
  end
end

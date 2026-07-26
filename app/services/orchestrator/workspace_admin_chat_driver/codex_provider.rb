require "json"

module Orchestrator
  module WorkspaceAdminChatDriver
    # Runs one non-interactive `codex exec` (or `codex exec resume`) turn and
    # normalizes its `--json` JSONL lines into WorkspaceAdminChatEvent hashes.
    # `codex exec resume` (confirmed against the installed 0.145.0 CLI) does
    # not accept -s/--sandbox at all -- only the first turn of a session sets
    # it; a resumed turn keeps whatever sandbox that session started with.
    module CodexProvider
      module_function

      DEFAULT_MODEL = WorkerSpawner::CODEX_WORKER_MODEL
      SANDBOX_MODE = "workspace-write"

      # See the identical constant on ClaudeProvider -- confirmed directly:
      # `codex exec resume <made-up-uuid> ...` exits 1 with a stderr line
      # containing exactly this phrase ("Error: thread/resume: thread/resume
      # failed: no rollout found for thread id ...").
      SESSION_MISSING_PATTERN = /no rollout found for thread id/i

      def run_turn(workspace_path:, prompt:, session_id:, model:, on_spawn: nil, &on_event)
        args = build_args(session_id:, model: model.presence || DEFAULT_MODEL, prompt:)
        env = WorkerSpawner.build_worker_env
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
        if session_id.present?
          [ "codex", "exec", "resume", session_id, "--json", "--model", model, prompt ]
        else
          [ "codex", "exec", "--json", "--model", model, "--sandbox", SANDBOX_MODE, prompt ]
        end
      end

      def parse_line(line)
        JSON.parse(line)
      rescue JSON::ParserError
        yield({ type: "error", message: "codex emitted malformed JSON", detail: line.byteslice(0, 500) })
        nil
      end

      def handle_event(envelope)
        case envelope["type"]
        when "thread.started"
          yield({ type: "session_started", session_id: envelope["thread_id"] }) if envelope["thread_id"].present?
        when "item.started"
          handle_item(envelope["item"], started: true) { |e| yield e }
        when "item.completed"
          handle_item(envelope["item"], started: false) { |e| yield e }
        when "turn.completed"
          yield({ type: "turn_completed", usage: envelope["usage"] || {} })
        when "turn.failed", "error"
          yield({ type: "error", message: envelope.dig("error", "message") || envelope["message"] || "codex turn failed", detail: envelope["error"] })
        end
      end

      def handle_item(item, started:)
        return unless item.is_a?(Hash)

        case item["type"]
        when "agent_message"
          yield({ type: "assistant_completed", text: item["text"].to_s }) unless started
        when "command_execution"
          handle_command_execution(item, started:) { |e| yield e }
        when "file_change"
          handle_file_change(item, started:) { |e| yield e }
        else
          handle_generic_item(item, started:) { |e| yield e }
        end
      end

      def handle_command_execution(item, started:)
        if started
          yield({ type: "tool_started", id: item["id"], name: "shell", detail: { command: item["command"] } })
        else
          yield({ type: "tool_completed", id: item["id"], result: { exit_code: item["exit_code"], output: item["aggregated_output"] } })
        end
      end

      def handle_file_change(item, started:)
        if started
          yield({ type: "tool_started", id: item["id"], name: "file_change", detail: { changes: item["changes"] } })
          return
        end

        yield({ type: "tool_completed", id: item["id"], result: { changes: item["changes"] } })
        Array(item["changes"]).each do |change|
          yield({ type: "file_changed", path: change["path"] }) if change.is_a?(Hash) && change["path"].present?
        end
      end

      def handle_generic_item(item, started:)
        if started
          yield({ type: "tool_started", id: item["id"], name: item["type"], detail: item })
        else
          yield({ type: "tool_completed", id: item["id"], result: item })
        end
      end

      # See the identical method on ClaudeProvider for why a signaled exit,
      # not a separate flag, is what "cancelled" means here.
      def cancelled?(result)
        result[:status]&.signaled? || false
      end

      def turn_errored?(result)
        !cancelled?(result) && !result[:status]&.success?
      end

      def report_process_error(result)
        return unless turn_errored?(result)

        yield({ type: "error", message: "codex exited #{result[:status]&.exitstatus}", detail: result[:stderr].presence })
      end
    end
  end
end

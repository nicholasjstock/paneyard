require "json"

module PaneyardPlugin
  # The model an agent session is on right now, read from the CLI's own
  # session log, which herdr's agent_session id names. The command line only
  # says what the session started on; `/model` changes it mid-session, and
  # only the log follows that.
  #
  # - claude: <config dir>/projects/<project>/<session id>.jsonl. Every
  #   assistant message carries the model id that answered. A `/model` switch
  #   is logged as "Set model to `Opus 5` ..." with the display name only, so
  #   a switch with no reply since comes back as `switched_to`, for the caller
  #   to match against the model list's labels.
  # - codex: <CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<time>-<session id>.jsonl,
  #   with a turn_context carrying the model for every turn, and a
  #   thread_settings_applied event with the new model id the moment /model
  #   switches (confirmed live with codex 0.159.3).
  #
  # Read-only, and nil whenever the log is missing or unreadable: the caller
  # falls back to the command line.
  module SessionModel
    Result = Struct.new(:id, :switched_to, keyword_init: true)

    # Large sessions run to megabytes; the newest entries are all that matter.
    TAIL_BYTES = 512 * 1024
    SESSION_ID = /\A[0-9A-Za-z-]+\z/
    SWITCH = /Set model to `([^`]+)`/

    module_function

    def for(driver, session_id, env: ENV)
      return unless session_id.is_a?(String) && session_id.match?(SESSION_ID)

      case driver
      when "claude" then claude(session_id, env)
      when "codex" then codex(session_id, env)
      end
    rescue SystemCallError, IOError
      nil
    end

    def claude(session_id, env)
      path = newest(claude_dirs(env).flat_map { |dir| Dir.glob(File.join(dir, "projects", "*", "#{session_id}.jsonl")) })
      return unless path

      switched_to = nil
      tail_entries(path).reverse_each do |entry|
        model = entry["type"] == "assistant" && entry.dig("message", "model")
        return Result.new(id: model, switched_to:) if model.is_a?(String) && !model.empty? && !model.start_with?("<")

        content = entry.dig("message", "content")
        switched_to ||= content[SWITCH, 1] if entry["type"] == "user" && content.is_a?(String)
      end
      switched_to && Result.new(id: nil, switched_to:)
    end

    def codex(session_id, env)
      path = newest(codex_dirs(env).flat_map { |dir| Dir.glob(File.join(dir, "sessions", "**", "rollout-*-#{session_id}.jsonl")) })
      return unless path

      tail_entries(path).reverse_each do |entry|
        payload = entry["payload"]
        next unless payload.is_a?(Hash)

        model = if entry["type"] == "turn_context"
          payload["model"]
        elsif entry["type"] == "event_msg" && payload["type"] == "thread_settings_applied"
          payload.dig("thread_settings", "model")
        end
        return Result.new(id: model) if model.is_a?(String) && !model.empty?
      end
      nil
    end

    # Where claude keeps its config: CLAUDE_CONFIG_DIR if herdr's server has
    # it, else both usual places.
    def claude_dirs(env)
      [ present(env["CLAUDE_CONFIG_DIR"]), File.join(home_dir(env), ".claude"), File.join(home_dir(env), ".config", "claude") ]
        .compact.uniq
    end

    # CODEX_HOME if herdr's server has it, else both usual places.
    def codex_dirs(env)
      [ present(env["CODEX_HOME"]), File.join(home_dir(env), ".codex"), File.join(home_dir(env), ".config", "codex") ].compact.uniq
    end

    def tail_entries(path)
      File.open(path, "rb") do |file|
        size = file.size
        file.seek([ size - TAIL_BYTES, 0 ].max)
        lines = file.read.force_encoding(Encoding::UTF_8).lines
        lines.shift if size > TAIL_BYTES # cut mid-line
        lines.filter_map do |line|
          entry = JSON.parse(line)
          entry if entry.is_a?(Hash)
        rescue JSON::ParserError
          nil
        end
      end
    end

    def newest(paths) = paths.max_by { |path| File.mtime(path) }
    def home_dir(env) = present(env["HOME"]) || Dir.home
    def present(value) = value.nil? || value.strip.empty? ? nil : value
  end
end

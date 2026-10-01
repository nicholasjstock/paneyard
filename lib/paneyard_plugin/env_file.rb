require "fileutils"

module PaneyardPlugin
  # The operator's settings: HERDR_PLUGIN_CONFIG_DIR/.env, in dotenv format.
  # Every key reaches the daemon as an environment variable -- the app
  # already reads all of its settings from ENV (credentials are only a
  # fallback), so this is the whole configuration surface -- except the ones
  # the plugin itself decides, which are ignored with a warning.
  #
  # Format: KEY=value, an optional leading `export`, `#` comments (also after
  # an unquoted value), single quotes taken literally, double quotes with \n,
  # \t, \" and \\ escapes, and a double-quoted value may span lines, which is
  # how a GitHub App private key fits.
  module EnvFile
    RESERVED = %w[
      RAILS_ENV BINDING PIDFILE HERDR_SOCKET_PATH PANEYARD_STORAGE_DIR PANEYARD_RUNTIME_DIR
      PANEYARD_RAILS_URL PANEYARD_HOT_RELOAD PANEYARD_SANDBOX PANEYARD_SANDBOX_ROOT PANEYARD_SANDBOX_REAL_HERDR
    ].freeze

    KEY = /\A[A-Za-z_][A-Za-z0-9_]*\z/

    SAMPLE = <<~ENV.freeze
      # Paneyard settings. Every line is optional; uncomment what you need.
      # Applied when Paneyard starts: run the "Restart Paneyard" action
      # (herdr plugin action invoke paneyard.restart --plugin paneyard) after a change.

      # Live agent sessions at once, across every workspace (default 4).
      # PANEYARD_MAX_CONCURRENT_RUNS=4

      # Default model per agent CLI. A model picked for a run wins.
      # PANEYARD_CLAUDE_MODEL=opus
      # PANEYARD_CODEX_MODEL=
      # PANEYARD_OPENCODE_MODEL=

      # Telegram remote control (docs/telegram.md).
      # TELEGRAM_BOT_TOKEN=
      # TELEGRAM_ALLOWED_USER_IDS=123456789

      # GitHub App for sessions' push credentials (GITHUB_APP_SETUP.md). Without
      # one, sessions use your own `gh auth token`.
      # GITHUB_APP_ID=
      # GITHUB_APP_INSTALLATION_ID=
      # GITHUB_APP_PRIVATE_KEY="-----BEGIN RSA PRIVATE KEY-----
      # ...
      # -----END RSA PRIVATE KEY-----"

      # A fixed port for the web UI and /mcp/admin. By default Paneyard picks a
      # free one the first time and keeps it.
      # PORT=

      # The Ruby to run Paneyard with, if the one found is not the right version.
      # PANEYARD_RUBY=/opt/homebrew/opt/ruby/bin/ruby
    ENV

    module_function

    # Returns [settings, warnings].
    def load(path)
      return [ {}, [] ] unless File.exist?(path)

      values, warnings = parse(File.read(path))
      reserved = values.keys & RESERVED
      warnings += reserved.map { |key| "#{path}: #{key} is set by the plugin itself, so it is ignored here" }
      [ values.except(*reserved), warnings ]
    end

    # Writes the commented sample, unless a file is already there.
    def write_sample(path)
      return false if File.exist?(path)

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, SAMPLE, mode: "wx", perm: 0o600)
      true
    rescue Errno::EEXIST
      false
    end

    # Returns [values, warnings].
    def parse(text)
      values = {}
      warnings = []
      lines = text.lines.map(&:chomp)
      index = 0
      while index < lines.length
        number = index + 1
        line = lines[index].strip
        index += 1
        next if line.empty? || line.start_with?("#")

        key, raw = line.delete_prefix("export ").split("=", 2).map(&:strip)
        unless raw && key.match?(KEY)
          warnings << "line #{number}: not KEY=value, ignored"
          next
        end

        if raw.start_with?('"')
          body = raw[1..]
          until (closing = closing_quote(body))
            if index >= lines.length
              warnings << "line #{number}: #{key} has no closing double quote, ignored"
              body = nil
              break
            end
            body = "#{body}\n#{lines[index]}"
            index += 1
          end
          values[key] = unescape(body[0...closing]) if body
        elsif raw.start_with?("'")
          closing = raw.index("'", 1)
          if closing
            values[key] = raw[1...closing]
          else
            warnings << "line #{number}: #{key} has no closing single quote, ignored"
          end
        else
          values[key] = raw.sub(/\s+#.*\z/, "")
        end
      end
      [ values, warnings ]
    end

    def closing_quote(body)
      escaped = false
      body.each_char.with_index do |char, position|
        if escaped
          escaped = false
        elsif char == "\\"
          escaped = true
        elsif char == '"'
          return position
        end
      end
      nil
    end

    def unescape(value)
      value.gsub(/\\([nrt"\\])/) { { "n" => "\n", "r" => "\r", "t" => "\t", '"' => '"', "\\" => "\\" }.fetch(Regexp.last_match(1)) }
    end
  end
end

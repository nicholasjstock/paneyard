require "fileutils"

module PaneyardPlugin
  # The operator's settings: HERDR_PLUGIN_CONFIG_DIR/.env, in dotenv format.
  # Every key reaches the daemon as an environment variable -- the app
  # reads all of its settings from ENV, so this is the whole configuration
  # surface -- except the ones
  # the plugin itself decides, which are ignored with a warning.
  #
  # Format: KEY=value, an optional leading `export`, `#` comments (also after
  # an unquoted value), single quotes taken literally, double quotes with \n,
  # \t, \" and \\ escapes, and a double-quoted value may span lines.
  module EnvFile
    RESERVED = %w[
      RAILS_ENV BINDING PIDFILE HERDR_SOCKET_PATH PANEYARD_STORAGE_DIR PANEYARD_RUNTIME_DIR
      PANEYARD_RAILS_URL PANEYARD_SANDBOX PANEYARD_SANDBOX_ROOT PANEYARD_SANDBOX_REAL_HERDR PANEYARD_ROLE
    ].freeze

    KEY = /\A[A-Za-z_][A-Za-z0-9_]*\z/

    SAMPLE = <<~ENV.freeze
      # Paneyard settings. Every line is optional; uncomment what you need.
      # Applied when Paneyard starts: run the "Paneyard: restart" action
      # (herdr plugin action invoke restart --plugin paneyard) after a change.

      # Live agent sessions at once, across every workspace (default 4).
      # PANEYARD_MAX_CONCURRENT_RUNS=4

      # Default model per agent CLI (claude: opus; codex: its own default).
      # A model picked when queueing wins.
      # PANEYARD_CLAUDE_MODEL=opus
      # PANEYARD_CODEX_MODEL=

      # Where this machine clones a workspace it has no checkout of, as
      # <directory>/<workspace name>, when a job runs here, and where new
      # projects go (default ~/Source). The setup action asks for it. With
      # PANEYARD_RUNNER_URL it is sent to the Paneyard this machine hosts
      # jobs for.
      # PANEYARD_PROJECTS_DIR=~/Source

      # A fixed port for /mcp/admin and /mcp/run. By default Paneyard picks a
      # free one the first time and keeps it.
      # PORT=

      # Use a Paneyard running on another machine instead of starting one
      # here: its URL (reachable from this one), and where checkouts here are
      # there, as local=remote path prefixes, comma-separated. Its jobs run
      # in that machine's herdr.
      # PANEYARD_REMOTE_URL=http://server.example.ts.net:7263
      # PANEYARD_REMOTE_PATHS=/Users/me=/home/me
      # The runner this machine is registered as, when that is not its host
      # name: what the queue popup offers by default once there are several.
      # PANEYARD_RUNNER_NAME=

      # With PANEYARD_REMOTE_URL, also host that Paneyard's jobs on this
      # machine: the plugin starts a runner here (bin/runner, loopback on
      # PANEYARD_RUNNER_PORT) and registers it there as PANEYARD_RUNNER_NAME
      # (default: this machine's hostname), reachable at PANEYARD_RUNNER_URL,
      # e.g. through `tailscale serve --bg --https=7264 http://127.0.0.1:7264`.
      # Checkouts here of that Paneyard's workspaces (found through
      # PANEYARD_REMOTE_PATHS) are registered with it.
      # PANEYARD_RUNNER_URL=https://laptop.example.ts.net:7264
      # PANEYARD_RUNNER_PORT=7264
      # PANEYARD_RUNNER_NAME=laptop

      # For a development checkout linked without the plugin build, an optional
      # Ruby override. Installed plugins use their bundled runtime.
      # PANEYARD_RUBY=/path/to/ruby
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

    # Sets KEY=value in the file, keeping everything else as it is: the
    # line that sets it is replaced, else the sample's commented-out one,
    # else it is appended. A missing file starts from the sample.
    def set(path, key, value)
      raise ArgumentError, "#{key} is not a setting name" unless key.match?(KEY)

      write_sample(path)
      lines = File.read(path).lines.map(&:chomp)
      line = "#{key}=#{quote(value)}"
      index = lines.index { |text| text.strip.delete_prefix("export ").match?(/\A#{Regexp.escape(key)}\s*=/) } ||
        lines.index { |text| text.match?(/\A#\s*#{Regexp.escape(key)}\s*=/) }
      index ? lines[index] = line : lines << line
      File.write(path, lines.join("\n") + "\n", perm: 0o600)
      value
    end

    # A value as parse reads it back: bare when it is plain, else in double
    # quotes.
    def quote(value)
      value = value.to_s
      return value if value.match?(%r{\A[A-Za-z0-9_./~:@%+,=-]*\z})

      escapes = { "\\" => "\\\\", '"' => '\\"', "\n" => "\\n", "\t" => "\\t", "\r" => "\\r" }
      '"' + value.gsub(/[\\"\n\t\r]/) { |char| escapes.fetch(char) } + '"'
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

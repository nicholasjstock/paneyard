require "open3"

module Orchestrator
  module Runner
    # The models each session driver can actually run on this machine, asked
    # of the installed CLI itself rather than hardcoded here, so
    # Orchestrator::ModelCatalog (which caches this) tracks whatever the
    # operator's own claude/codex offers.
    #
    # Neither has one uniform "list models" command, so each is read
    # from wherever that CLI keeps its own list:
    #   - claude has no subcommand for it, but caches the catalog it fetched for
    #     its own /model picker at <config dir>/cache/model-catalog/*-cc.json;
    #   - codex prints its catalog as JSON with `codex debug models`
    #     (visibility "hide" entries are internal and never shown in its picker).
    #
    # A driver whose CLI is missing or whose output cannot be read yields an
    # empty list, never an error: the form then only offers the driver's
    # default (Orchestrator::DefaultModels), which is exactly what a run did
    # before a model could be picked at all.
    module ModelDiscovery
      module_function

      COMMAND_TIMEOUT_SECONDS = 10

      # [{ "id" => "claude-opus-5-5", "label" => "Opus 5.5 — claude-opus-5-5" }, ...]
      def models_for(driver)
        case driver
        when "claude" then claude_models
        when "codex" then codex_models
        else []
        end
      rescue StandardError => error
        Rails.logger.warn("[ModelDiscovery] could not list #{driver} models: #{error.class}: #{error.message}")
        []
      end

      def claude_models
        path = claude_catalog_path
        return [] unless path

        JSON.parse(File.read(path)).dig("catalog", "config", "models").to_a.filter_map do |model|
          next if model["id"].blank?

          option(model["id"], model["name"])
        end
      end

      # CLAUDE_CONFIG_DIR is where claude itself looks first; the other two are
      # its default and the XDG location, for a Rails process started without
      # the operator's shell environment.
      def claude_catalog_path
        dirs = [ ENV["CLAUDE_CONFIG_DIR"].presence, "~/.claude", "~/.config/claude" ].compact
        dirs.flat_map { |dir| Dir.glob(File.join(File.expand_path(dir), "cache", "model-catalog", "*-cc.json")) }
          .max_by { |path| File.mtime(path) }
      end

      def codex_models
        output = capture("codex", "debug", "models")
        return [] unless output

        JSON.parse(output).fetch("models", [])
          .reject { |model| model["slug"].blank? || model["visibility"] == "hide" }
          .sort_by { |model| model["priority"] || Float::INFINITY }
          .map { |model| option(model["slug"], model["display_name"]) }
      end

      # The id is what goes on the command line; the label shows it next to the
      # CLI's own display name, since that name alone hides which version it is.
      def option(id, name = nil)
        label = name.present? && !name.casecmp?(id) ? "#{name} — #{id}" : id
        { "id" => id, "label" => label }
      end

      # stdout of a successful, timely exit, or nil. A CLI that hangs (waiting
      # on a login prompt, say) must not hang the page that asked.
      def capture(*command)
        Open3.popen3(*command, pgroup: true) do |stdin, stdout, stderr, wait_thread|
          stdin.close
          # Drained concurrently so neither pipe can fill and stall the CLI; a
          # read cut short by the pipes closing after a timeout is just nil.
          stderr_reader = Thread.new { stderr.read rescue nil }
          stdout_reader = Thread.new { stdout.read rescue nil }

          unless wait_thread.join(COMMAND_TIMEOUT_SECONDS)
            Process.kill("KILL", -wait_thread.pid) rescue Errno::ESRCH
            return nil
          end

          output = stdout_reader.value
          stderr_reader.value
          wait_thread.value.success? ? output : nil
        end
      rescue Errno::ENOENT
        nil
      end
    end
  end
end

require "fileutils"
require "json"

module Orchestrator
  module Runner
    # Copies of the CLI's own conversation transcripts for a run, kept on the
    # runner's machine beside the run's other runtime files
    # (<runtime root>/<run>/transcripts/<driver>/). The CLIs keep the
    # originals in their own config, where they are pruned (claude's
    # cleanupPeriodDays) and nothing ties them to a run; run-20261012-174300-3933
    # was a case where whether one existed at all was the evidence.
    #
    # Both CLIs file a conversation under the directory it ran in, and every
    # run has its own worktree, so a run's transcripts are found by its
    # worktree path alone, with no session id needed -- a session that never
    # reported one (or never started a conversation) is still covered:
    #
    #   - claude: <config>/projects/<cwd with every character but letters
    #     and digits turned into "-">/, where <config> is CLAUDE_CONFIG_DIR or
    #     ~/.claude, and also ~/.claude and ~/.config/claude where they exist
    #     (claude_config_dirs: the login shell's may differ), one <id>.jsonl
    #     per conversation, beside per-conversation directories (subagents,
    #     tool results). The whole directory is copied.
    #   - codex: <CODEX_HOME or ~/.codex>/sessions/YYYY/MM/DD/rollout-*.jsonl,
    #     whose first line (session_meta) names its cwd. Only the day
    #     directories since the session started are read.
    #
    # Copies are refreshed each time, so a reopened run's resumed
    # conversation replaces its older copy with the longer one.
    module Transcripts
      module_function

      def dir(runtime_root, run_id)
        File.join(runtime_root.to_s, Attachments.sanitize_run_id(run_id), "transcripts")
      end

      # Copies what it finds and returns the conversation files it saved
      # (each a transcript, not the supporting files beside it), sorted.
      #
      # A sandbox only reads the transcripts of a worktree inside its root: a
      # production copy's runs name the operator's real worktrees.
      def save(runtime_root:, run_id:, driver:, cwd:, since:)
        Sandbox.guard_path!(cwd, "save the CLI transcripts of")
        target = File.join(dir(runtime_root, run_id), driver.to_s)
        case driver.to_s
        when "claude" then save_claude(target, cwd)
        when "codex" then save_codex(target, cwd, since)
        else []
        end
      end

      def save_claude(target, cwd)
        sources = claude_project_dirs(cwd).select { |path| Dir.exist?(path) }
        sources.each do |source|
          FileUtils.mkdir_p(target)
          FileUtils.cp_r(File.join(source, "."), target)
        end
        return [] if sources.empty?

        Dir.glob(File.join(target, "*.jsonl")).sort
      end

      # The cwd as given and as the filesystem resolves it (/tmp is
      # /private/tmp on macOS), since which one claude saw is not known, in
      # every config directory claude might use (claude_config_dirs).
      def claude_project_dirs(cwd)
        paths = [ cwd.to_s ]
        paths << File.realpath(cwd.to_s) if File.exist?(cwd.to_s)
        claude_config_dirs.product(paths.uniq).map do |config, path|
          File.join(config, "projects", path.gsub(/[^A-Za-z0-9]/, "-"))
        end.uniq
      end

      # claude runs in the operator's login shell, whose CLAUDE_CONFIG_DIR
      # this process may not have (as for ClaudeTrust): the herdr plugin's
      # daemon was confirmed live to run without it, saving and placing
      # transcripts under ~/.claude while claude used ~/.config/claude, so a
      # moved run's conversation could not be resumed. So this process's own
      # directory, and each usual one that exists.
      def claude_config_dirs
        [ claude_config_dir, *usual_claude_config_dirs.select { |dir| Dir.exist?(dir) } ].map { |dir| File.expand_path(dir) }.uniq
      end

      def claude_config_dir
        ENV["CLAUDE_CONFIG_DIR"].presence || File.join(Dir.home, ".claude")
      end

      def usual_claude_config_dirs
        [ File.join(Dir.home, ".claude"), File.join(Dir.home, ".config", "claude") ]
      end

      def save_codex(target, cwd, since)
        cwds = [ cwd.to_s ]
        cwds << File.realpath(cwd.to_s) if File.exist?(cwd.to_s)
        codex_rollouts(since).select { |path| cwds.include?(codex_cwd(path)) }.map do |source|
          FileUtils.mkdir_p(target)
          FileUtils.cp(source, target)
          File.join(target, File.basename(source))
        end.sort
      end

      def codex_rollouts(since)
        start = (since.present? ? Time.iso8601(since.to_s) : Time.now).utc.to_date - 1
        (start..(Date.today + 1)).flat_map do |day|
          Dir.glob(File.join(codex_home, "sessions", day.strftime("%Y/%m/%d"), "rollout-*.jsonl"))
        end
      end

      def codex_cwd(path)
        first = File.open(path, &:gets)
        first && JSON.parse(first).dig("payload", "cwd")
      rescue JSON::ParserError, SystemCallError
        nil
      end

      def codex_home
        ENV["CODEX_HOME"].presence || File.join(Dir.home, ".codex")
      end

      # --- Moving a run (RunTransfer, Orchestrator::RunMove) ------------------

      # Every file saved for the run, for the machine it moves to:
      # [{ "driver", "path" (relative to that driver's directory), "content"
      # (binary) }].
      def export(runtime_root:, run_id:)
        root = dir(runtime_root, run_id)
        Dir.glob(File.join(root, "*", "**", "*")).sort.filter_map do |file|
          next unless File.file?(file) && !File.symlink?(file)

          driver, relative = file.delete_prefix("#{root}/").split("/", 2)
          { "driver" => driver, "path" => relative, "content" => File.binread(file).force_encoding(Encoding::BINARY) }
        end
      end

      # Puts a moved run's transcripts where this machine's CLI looks for the
      # conversations of `cwd`, its new worktree, so that resuming one there
      # has a chance (whether it works across machines is for the operator to
      # confirm live), and keeps a copy beside the run's runtime files as save
      # does. Each conversation's own record of where it ran (`cwd` in claude's
      # lines, the session_meta and turn context in codex's) is rewritten from
      # source_cwd to cwd.
      #
      #   claude  <config>/projects/<encoded cwd>/<same relative path>
      #   codex   <home>/sessions/YYYY/MM/DD/<rollout file>, dated from its name
      #
      # A sandbox writes into a CLI's config only when that config is inside
      # its root, and otherwise keeps only the runtime copy. Returns
      # { "saved", "placed" (paths), "skipped" (why some were not placed) }.
      def restore(runtime_root:, run_id:, cwd:, source_cwd:, transcripts:)
        Sandbox.guard_path!(cwd, "restore the CLI transcripts of")
        saved = []
        placed = []
        skipped = []
        Array(transcripts).each do |transcript|
          driver = transcript.fetch("driver").to_s
          relative = safe_relative(transcript.fetch("path").to_s)
          next skipped << "#{driver}/#{transcript['path']}: not a plain relative path" unless relative && %w[claude codex].include?(driver)

          content = transcript.fetch("content").to_s.b
          saved << write(File.join(dir(runtime_root, run_id), driver, relative), content)
          content = relocate(content, from: source_cwd.to_s, to: cwd.to_s) if relative.end_with?(".jsonl") && source_cwd.present?
          destinations = driver == "claude" ? claude_destinations(cwd, relative) : [ codex_destination(relative) ]
          destinations.each do |destination|
            Sandbox.guard_path!(destination, "write a CLI transcript to")
            placed << write(destination, content)
          rescue Sandbox::Violation => error
            skipped << error.message
          end
        end
        { "saved" => saved, "placed" => placed, "skipped" => skipped.uniq }
      end

      def claude_destinations(cwd, relative)
        claude_project_dirs(cwd).map { |project| File.join(project, relative) }
      end

      # A rollout file's name starts with its date (rollout-YYYY-MM-DDT...),
      # which is the day directory codex files it under.
      def codex_destination(relative)
        name = File.basename(relative)
        day = name[/\Arollout-(\d{4})-(\d{2})-(\d{2})/] ? [ ::Regexp.last_match(1), ::Regexp.last_match(2), ::Regexp.last_match(3) ] : Time.now.utc.strftime("%Y/%m/%d").split("/")
        File.join(codex_home, "sessions", *day, name)
      end

      def safe_relative(path)
        parts = path.split("/")
        return nil if path.start_with?("/") || parts.empty? || parts.any? { |part| part.empty? || part == "." || part == ".." }

        parts.join("/")
      end

      def write(path, content)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, content)
        path
      end

      # Each JSON line whose cwd (top level, or in its payload) is source_cwd,
      # or inside it, gets the new one. Lines that are not JSON stay as they are.
      def relocate(content, from:, to:)
        content.force_encoding(Encoding::UTF_8)
        return content.b unless content.valid_encoding?

        content.each_line.map do |line|
          record = JSON.parse(line)
          next line unless record.is_a?(Hash)

          changed = relocate_cwd!(record, from:, to:)
          changed |= relocate_cwd!(record["payload"], from:, to:) if record["payload"].is_a?(Hash)
          changed ? "#{JSON.generate(record)}#{"\n" if line.end_with?("\n")}" : line
        rescue JSON::ParserError
          line
        end.join.b
      end

      def relocate_cwd!(record, from:, to:)
        cwd = record["cwd"]
        return false unless cwd.is_a?(String) && (cwd == from || cwd.start_with?("#{from}/"))

        record["cwd"] = "#{to}#{cwd.delete_prefix(from)}"
        true
      end
    end
  end
end

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
    #   - claude: <CLAUDE_CONFIG_DIR or ~/.claude>/projects/<cwd with every
    #     character but letters and digits turned into "-">/, one <id>.jsonl
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
      # /private/tmp on macOS), since which one claude saw is not known.
      def claude_project_dirs(cwd)
        paths = [ cwd.to_s ]
        paths << File.realpath(cwd.to_s) if File.exist?(cwd.to_s)
        paths.uniq.map { |path| File.join(claude_config_dir, "projects", path.gsub(/[^A-Za-z0-9]/, "-")) }
      end

      def claude_config_dir
        ENV["CLAUDE_CONFIG_DIR"].presence || File.join(Dir.home, ".claude")
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
    end
  end
end

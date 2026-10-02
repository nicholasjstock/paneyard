module Orchestrator
  # The single document handed to a run's session as live input, as
  # its first user message. There is no system prompt and no MCP-server
  # instructions carrying the lifecycle, so this is the one place every driver
  # is guaranteed to read it.
  #
  # Deliberately short, and meaningful in any target repo. The session is a
  # real interactive CLI in the worktree and reads the repo's own
  # CLAUDE.md/AGENTS.md for how to work on the code; this covers only what the
  # repo cannot tell it: which run it is, what to do with its changes, and how
  # to report back. How to write a good report lives in report_idle's own
  # `summary` description, where it is read at the moment of writing one.
  #
  # A session leaves its changes uncommitted so the operator can try them
  # first; committing, pushing and merging back into the run's base branch
  # happen only when asked.
  module RunPrompt
    module_function

    def compose(run:, session_driver:)
      [
        header_section(run),
        changes_section(run),
        reporting_section(session_driver),
        attachments_section(run),
        task_section(run)
      ].compact.join("\n")
    end

    # A reopened run's fresh session (SessionReopen): the usual prompt, with
    # what it is picking up before the task, since its own conversation is
    # gone and the newest report is the only account of where the run stands.
    def compose_reopened(run:, session_driver:)
      [
        header_section(run),
        changes_section(run),
        reporting_section(session_driver),
        attachments_section(run),
        reopened_section(run),
        task_section(run)
      ].compact.join("\n")
    end

    # What a resumed conversation is told: it already knows the task and the
    # rules, only not that it was closed and has come back.
    def compose_resumed(run:)
      <<~PROMPT
        The operator closed this session and has now reopened run #{run.run_id}, resuming this conversation. Your
        worktree `#{run.target_root}` on branch `#{run.branch_name}` holds the run's work: kept as it was, or, if it
        was removed while closed (only ever once its work was saved), made again from the branch. Your `paneyard`
        MCP connection is a new one; report through `report_idle` as before. Do not start new work on your own:
        check the worktree is as you left it, call `report_idle` with where the run stands, and wait for the
        operator.
      PROMPT
    end

    def header_section(run)
      base = run.base_sha.present? ? " (from `#{run.base_branch}` at #{run.base_sha.first(12)})" : " (from `#{run.base_branch}`)"

      <<~SECTION
        # Run #{run.run_id}

        Worktree `#{run.target_root}`, branch `#{run.branch_name}`#{base}. It is yours alone. Follow the repo's own
        AGENTS.md / CLAUDE.md.
      SECTION
    end

    # The run merges back into the branch it started from, which need not be
    # the one the operator's checkout has out, or checked out anywhere.
    def changes_section(run)
      repository = run.source_root.presence || run.workspace.repository_path
      base = run.base_branch
      branch = run.branch_name

      <<~SECTION
        Leave your changes uncommitted: the operator tries them out and decides what to keep. Commit, push and merge
        are separate: do only the one you are asked for. "Commit" means a local commit on this branch, nothing more.
        Push only when told to push. Merge only when told to merge, into `#{base}`, the branch this run started from
        (no push needed first): where `#{base}` is checked out (`git worktree list`) and clean, `git -C <there> merge
        #{branch}`; if it is checked out nowhere, `git -C #{repository} fetch . #{branch}:#{base}` fast-forwards it.
        Never switch, reset or stash the operator's checkout at `#{repository}`; if neither works, report `blocked`.
      SECTION
    end

    def reporting_section(session_driver)
      section = <<~SECTION
        Whenever you stop -- finished, stuck, or giving up -- call `report_idle` (MCP server `paneyard`) with `done`,
        `blocked` or `failed`. The operator reads these reports, not this terminal, so a question goes in a `blocked`
        summary. Reporting does not end the run; if more work comes, report again.
      SECTION
      # Only Claude Code defers MCP tools behind ToolSearch; codex has no such
      # tool and names MCP tools differently.
      section += "If report_idle is not listed, load it with ToolSearch: `select:mcp__paneyard__report_idle`.\n" if session_driver == "claude"
      section
    end

    # Launch uploads are stored before the run has a worktree, beside its
    # runtime files on the runner.
    def attachments_section(run)
      names = Array(run.launch_artifacts).filter_map { |artifact| artifact["name"] || artifact[:name] }
      return if names.empty?

      dir = Runner.for(run.workspace).attachments_dir(run_id: run.run_id)
      "Attached files: #{names.join(', ')}, in `#{dir}`.\n"
    end

    def reopened_section(run)
      checkpoint = run.checkpoints.last
      report =
        if checkpoint
          "Its newest report (`#{checkpoint.outcome}`, #{checkpoint.created_at.utc.iso8601}):\n\n#{checkpoint.summary}\n\n"
        else
          "It never reported.\n\n"
        end

      <<~SECTION
        # Reopened

        This run had a session before, which was closed; the operator has reopened it, and its conversation could
        not be resumed, so you start fresh. The work so far is in this worktree: commits on `#{run.branch_name}` since
        `#{run.base_branch}`, and anything left uncommitted. #{report}Do not start new work on your own: check the
        worktree (`git status`, `git log #{run.base_branch}..HEAD`) against that report and the task below, call
        `report_idle` with where the run stands, and wait for the operator.
      SECTION
    end

    def task_section(run)
      <<~SECTION
        # Task

        #{run.task}
      SECTION
    end
  end
end

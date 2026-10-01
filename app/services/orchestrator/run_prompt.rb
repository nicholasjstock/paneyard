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

    # Launch uploads are stored (RunsController#uploaded_artifacts) before the
    # run has a worktree, beside its runtime files on the runner.
    def attachments_section(run)
      names = Array(run.launch_artifacts).filter_map { |artifact| artifact["name"] || artifact[:name] }
      return if names.empty?

      dir = Runner.for(run.workspace).attachments_dir(run_id: run.run_id)
      "Attached files: #{names.join(', ')}, in `#{dir}`.\n"
    end

    def task_section(run)
      <<~SECTION
        # Task

        #{run.task}
      SECTION
    end
  end
end

require "shellwords"

module Orchestrator
  # The single document handed to a run's session via Herdr.agent_prompt.
  #
  # This replaces the old three-layer assembly (workspace memory + per-worker
  # identity + a role persona file + "Current task:"). There are no roles left
  # to have personas for: one session does the whole job, so it gets one flat
  # briefing.
  #
  # Deliberately short. The session is a real interactive CLI running in the
  # worktree, so it loads the target repo's own CLAUDE.md/AGENTS.md the way it
  # would for the operator -- this prompt covers only what the repo cannot
  # tell it: which run it is, how to report back, and what Rails will do with
  # the branch afterwards.
  module RunPrompt
    module_function

    def compose(run:, session_driver:)
      sections = [
        memory_section(run),
        identity_section(run:, session_driver:),
        working_agreement(run),
        task_section(run)
      ]
      sections.compact_blank.join("\n")
    end

    # Prepended so no session has to remember to ask -- see ProjectMemory and
    # RecordProjectMemoryEntryTool for how these get written. Reuses
    # ProjectMemory.snapshot's own brief bound rather than querying the table.
    def memory_section(run)
      entries = ProjectMemory.snapshot(run_id: run.run_id)[:entries]
      return nil if entries.empty?

      lines = entries.map { |entry| "- [#{entry[:kind]}] #{entry[:key]}: #{entry[:content]}" }
      <<~SECTION
        # Durable project knowledge for this workspace

        Evidence-backed notes from earlier runs. Call `get_project_memory` for full detail.

        #{lines.join("\n")}
      SECTION
    end

    def identity_section(run:, session_driver:)
      <<~SECTION
        # Runtime identity (authoritative)

        - runId: #{run.run_id}
        - workspace: #{run.workspace.name}
        - worktree: #{run.target_root}
        - branch: #{run.branch_name || "(not provisioned)"}

        Rails authenticates your MCP calls with this session's private capability -- do not invent or
        alter identity fields. The workflow tools are MCP tools registered under the `mcp__workflow__`
        prefix (e.g. `mcp__workflow__report_idle`). If they are not directly callable they are deferred:
        load them FIRST with ToolSearch using their full prefixed names (e.g. query
        `select:mcp__workflow__report_idle`) -- bare, unprefixed names will not match. Never state or imply
        that you called a tool you did not actually invoke; if a required tool cannot be loaded or
        called, say exactly that instead of narrating a call that never happened.
      SECTION
    end

    def working_agreement(run)
      <<~SECTION
        # How this run works

        You own this worktree end to end. It is a real git worktree on branch `#{run.branch_name}`,
        checked out at `#{run.target_root}`, and nobody else is working in it -- you do not need to
        coordinate, ask permission for ordinary changes, or scope your edits to a pre-approved file list.

        An operator is watching this pane and can type into it. If you are genuinely blocked on a
        decision only they can make, ask here and wait -- that is cheaper than guessing.

        When the work is finished:

        1. Commit your work and push the branch: `git push -u origin #{run.branch_name}`.
        2. Call `report_idle` with outcome `done`.

        `report_idle` does not end the run. It tells the operator you have stopped working, and its
        summary is the record of what you did: the run screen shows the reports in order and nothing
        else, so the operator reads them instead of this pane. Write each summary as a full report in
        Markdown, not a one-liner -- what you changed and why, how it was verified (commands run and their
        results), what failed or was left out, what state the worktree and branch are in, and what you
        think should happen next. The operator may send you more work; if so, do it and call
        `report_idle` again when you next go idle. Each report covers only the interval since your
        previous one and they are kept as the run's history, so do not restate earlier reports.

        If you cannot finish, report anyway -- `blocked` if you need the operator, `failed` if the task
        cannot be done as specified -- and say why. Do not end your turn without calling it: until you do,
        Rails cannot tell you are idle rather than still working, and the run holds a concurrency slot.
      SECTION
    end

    def task_section(run)
      artifacts = Array(run.launch_artifacts).filter_map { |artifact| artifact["name"] || artifact[:name] }
      attached =
        if artifacts.any?
          "\nFiles attached at launch (read them with `read_workflow_artifact`): #{artifacts.join(', ')}.\n"
        end

      <<~SECTION
        # Task
        #{attached}
        #{run.task}
      SECTION
    end
  end
end

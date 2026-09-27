require "rails_helper"

RSpec.describe Orchestrator::RunSessionRunner do
  let(:run) do
    create_run(
      prefix: "session-runner", status: "launching",
      target_root: Dir.mktmpdir("session-runner-worktree"), branch_name: "workflow/session-runner",
      worktree_name: "session-runner-a1b2"
    )
  end

  before do
    # gh/GitHub App resolution shells out; the session's environment is
    # SessionEnv's concern, not this module's.
    allow(Orchestrator::SessionEnv).to receive(:for_session).and_return({ "FOO" => "bar" })
    allow(Orchestrator::Herdr).to receive(:notify)
    # Every failure path closes the pane's workspace; stubbed here so no
    # example can reach the real socket through it.
    allow(Orchestrator::Herdr).to receive(:workspace_close)
    # The default layout's nvim pane beside the agent. PATH is stubbed so
    # examples do not depend on whether this machine has nvim installed.
    allow(Orchestrator::WorkspaceLayout).to receive(:executable_on_path?).with("nvim").and_return(true)
    allow(Orchestrator::Herdr).to receive(:pane_split)
      .and_return("pane_id" => "w9:p2", "tab_id" => "w9:t1", "workspace_id" => "w9")
    allow(Orchestrator::Herdr).to receive(:pane_send_input)
    allow(Orchestrator::Herdr).to receive(:pane_rename)
    allow(Orchestrator::Herdr).to receive(:tab_rename)
    allow(Orchestrator::Herdr).to receive(:tab_create)
      .and_return("tab" => { "tab_id" => "w9:t2" }, "root_pane" => { "pane_id" => "w9:p3" })
    stub_const("#{described_class}::SHELL_POLL_INTERVAL_SECONDS", 0)
    stub_const("#{described_class}::PROMPT_SUBMIT_POLL_INTERVAL_SECONDS", 0)
  end

  # An idle pane: the shell itself is the only thing in the foreground.
  def idle_shell_info(shell_pid: 100)
    { "shell_pid" => shell_pid, "foreground_process_group_id" => shell_pid,
      "foreground_processes" => [ { "pid" => shell_pid, "name" => "zsh" } ] }
  end

  # A pane whose shell is still running its own rc files, which is what herdr
  # refuses to launch an agent into.
  def busy_shell_info(shell_pid: 100)
    { "shell_pid" => shell_pid, "foreground_process_group_id" => 301,
      "foreground_processes" => [ { "pid" => 301, "name" => "bash" } ] }
  end

  # A pane with the launched agent holding the foreground; its process group is
  # what start! records as the session pid.
  def running_agent_info(shell_pid: 100, pid: 555)
    { "shell_pid" => shell_pid, "foreground_process_group_id" => pid,
      "foreground_processes" => [ { "pid" => pid, "name" => "claude" } ] }
  end

  def stub_successful_launch(pane_id: "w9:p1", agent_status: "working")
    # The pane is idle at its shell prompt until the agent launches into it,
    # and the agent holds the foreground from then on. Driven off the launch
    # rather than a fixed call sequence so this survives a retried launch, and
    # a second start! (whose fresh pane is idle again) in the same example.
    launched = false
    allow(Orchestrator::Herdr).to receive(:workspace_create) do
      launched = false
      { "root_pane" => { "pane_id" => pane_id, "tab_id" => "w9:t1", "workspace_id" => "w9" } }
    end
    allow(Orchestrator::Herdr).to receive(:agent_get)
      .and_return("interactive_ready" => true, "agent_status" => agent_status)
    allow(Orchestrator::Herdr).to receive(:agent_prompt)
    allow(Orchestrator::Herdr).to receive(:agent_start) { launched = true; nil }
    allow(Orchestrator::Herdr).to receive(:pane_process_info) { launched ? running_agent_info : idle_shell_info }
  end

  describe ".start!" do
    it "opens a pane in the worktree, launches the agent, submits the prompt, and records the process group" do
      stub_successful_launch

      session = described_class.start!(run)

      expect(Orchestrator::Herdr).to have_received(:workspace_create)
        .with(hash_including(label: "session-runner-a1b2", cwd: run.target_root, focus: false))
      expect(Orchestrator::Herdr).to have_received(:agent_start)
        .with(hash_including(kind: "claude", pane_id: "w9:p1"))
      # The prompt is live input, never an argv element.
      expect(Orchestrator::Herdr).to have_received(:agent_prompt).with("w9:p1", a_string_including(run.task))

      expect(session).to have_attributes(status: "running", pid: 555, herdr_pane_id: "w9:p1", driver: "claude")
      expect(File.read(session.prompt_path)).to include(run.task)
    end

    it "splits nvim opened on the worktree beside the agent by default, and keeps tracking only the agent pane" do
      stub_successful_launch

      session = described_class.start!(run)

      expect(Orchestrator::Herdr).to have_received(:pane_split).with(
        target_pane_id: "w9:p1", direction: "right", ratio: nil, cwd: run.target_root, env: { "FOO" => "bar" },
        focus: false
      )
      expect(Orchestrator::Herdr).to have_received(:pane_send_input).with("w9:p2", text: "nvim .", keys: [ "Enter" ])
      expect(Orchestrator::Herdr).to have_received(:agent_start).with(hash_including(pane_id: "w9:p1"))
      expect(Orchestrator::Herdr).not_to have_received(:agent_prompt).with("w9:p2", anything)
      expect(session).to have_attributes(status: "running", herdr_pane_id: "w9:p1", herdr_workspace_id: "w9")
    end

    it "launches with just the agent pane when nvim is not on PATH" do
      stub_successful_launch
      allow(Orchestrator::WorkspaceLayout).to receive(:executable_on_path?).with("nvim").and_return(false)

      session = described_class.start!(run)

      expect(Orchestrator::Herdr).not_to have_received(:pane_split)
      expect(Orchestrator::Herdr).not_to have_received(:pane_send_input)
      expect(session).to have_attributes(status: "running", herdr_pane_id: "w9:p1")
    end

    it "launches with just the agent pane when herdr refuses the split" do
      stub_successful_launch
      allow(Orchestrator::Herdr).to receive(:pane_split).and_raise(Orchestrator::Herdr::Error, "no such pane")

      session = described_class.start!(run)

      expect(Orchestrator::Herdr).not_to have_received(:pane_send_input)
      expect(Orchestrator::Herdr).not_to have_received(:workspace_close)
      expect(session).to have_attributes(status: "running", pid: 555, herdr_pane_id: "w9:p1")
    end

    it "opens the workspace's own layout: extra tabs and splits, all with the session env, the agent still tracked" do
      stub_successful_launch
      run.workspace.update!(layout: <<~YAML)
        tabs:
          - name: main
            panes:
              - agent
          - name: logs
            panes:
              - name: dev-log
                command: tail -f log/development.log
              - name: test-log
                command: tail -f log/test.log
                split: { of: dev-log, direction: down }
      YAML
      allow(Orchestrator::Herdr).to receive(:pane_split)
        .and_return("pane_id" => "w9:p4", "tab_id" => "w9:t2", "workspace_id" => "w9")

      session = described_class.start!(run)

      expect(Orchestrator::Herdr).to have_received(:tab_rename).with("w9:t1", "main")
      expect(Orchestrator::Herdr).to have_received(:tab_create)
        .with(workspace_id: "w9", label: "logs", cwd: run.target_root, env: { "FOO" => "bar" }, focus: false)
      expect(Orchestrator::Herdr).to have_received(:pane_send_input)
        .with("w9:p3", text: "tail -f log/development.log", keys: [ "Enter" ])
      expect(Orchestrator::Herdr).to have_received(:pane_split).with(
        hash_including(target_pane_id: "w9:p3", direction: "down", env: { "FOO" => "bar" }, focus: false)
      )
      expect(Orchestrator::Herdr).to have_received(:pane_send_input)
        .with("w9:p4", text: "tail -f log/test.log", keys: [ "Enter" ])
      expect(session).to have_attributes(status: "running", herdr_pane_id: "w9:p1", herdr_tab_id: "w9:t1")
    end

    it "launches the agent even when a layout tab cannot be opened" do
      stub_successful_launch
      run.workspace.update!(layout: "tabs:\n  - panes: [agent]\n  - panes: [{ name: logs, command: tail -f x }]\n")
      allow(Orchestrator::Herdr).to receive(:tab_create).and_raise(Orchestrator::Herdr::Error, "boom")

      session = described_class.start!(run)

      expect(Orchestrator::Herdr).not_to have_received(:workspace_close)
      expect(session).to have_attributes(status: "running", herdr_pane_id: "w9:p1")
    end

    it "still launches the agent when nvim cannot be typed into the split pane" do
      stub_successful_launch
      allow(Orchestrator::Herdr).to receive(:pane_send_input).and_raise(Orchestrator::Herdr::Unreachable, "timed out")

      session = described_class.start!(run)

      expect(Orchestrator::Herdr).to have_received(:agent_start).once
      expect(session).to have_attributes(status: "running", herdr_pane_id: "w9:p1")
    end

    # A fresh pane's shell runs the operator's rc files (pyenv, starship, git)
    # before it is idle, and herdr rejects agent.start for the whole of that
    # window. Rails writes the session row between workspace.create and
    # agent.start, which put the launch squarely inside it.
    it "waits for the pane's shell to go idle before launching the agent" do
      stub_successful_launch
      allow(Orchestrator::Herdr).to receive(:pane_process_info).and_return(
        busy_shell_info, busy_shell_info,
        *Array.new(described_class::SHELL_STABLE_SAMPLES) { idle_shell_info },
        running_agent_info
      )

      described_class.start!(run)

      expect(Orchestrator::Herdr).to have_received(:agent_start).once
    end

    # A single idle sample can be a gap between two rc files rather than the
    # end of startup.
    it "requires consecutive idle samples rather than one" do
      stub_successful_launch
      allow(Orchestrator::Herdr).to receive(:pane_process_info).and_return(
        idle_shell_info, busy_shell_info,
        *Array.new(described_class::SHELL_STABLE_SAMPLES) { idle_shell_info },
        running_agent_info
      )

      described_class.start!(run)

      expect(Orchestrator::Herdr).to have_received(:agent_start).once
    end

    # The poll cannot close the gap between its last sample and agent.start.
    it "retries the launch when herdr still reports the pane is not an available shell" do
      stub_successful_launch
      attempts = 0
      launched = false
      allow(Orchestrator::Herdr).to receive(:agent_start) do
        attempts += 1
        raise Orchestrator::Herdr::Error, "agent target pane w9:p1 is not an available shell" if attempts == 1

        launched = true
        nil
      end
      allow(Orchestrator::Herdr).to receive(:pane_process_info) { launched ? running_agent_info : idle_shell_info }

      session = described_class.start!(run)

      expect(Orchestrator::Herdr).to have_received(:agent_start).twice
      expect(session.status).to eq("running")
    end

    it "gives up and fails the session when every launch attempt is rejected" do
      stub_successful_launch
      allow(Orchestrator::Herdr).to receive(:agent_start)
        .and_raise(Orchestrator::Herdr::Error, "agent target pane w9:p1 is not an available shell")
      allow(Orchestrator::Herdr).to receive(:pane_process_info).and_return(idle_shell_info)

      expect { described_class.start!(run) }.to raise_error(Orchestrator::Herdr::Error, /not an available shell/)

      expect(Orchestrator::Herdr).to have_received(:agent_start).exactly(described_class::AGENT_START_ATTEMPTS).times
      expect(Orchestrator::Herdr).to have_received(:workspace_close).with("w9")
      expect(run.run_sessions.sole).to have_attributes(status: "failed", outcome: "failed")
    end

    # An unrelated herdr failure must not be retried as if it were the race.
    it "does not retry a launch that failed for any other reason" do
      stub_successful_launch
      allow(Orchestrator::Herdr).to receive(:agent_start)
        .and_raise(Orchestrator::Herdr::Error, "unknown agent kind")

      expect { described_class.start!(run) }.to raise_error(Orchestrator::Herdr::Error, /unknown agent kind/)

      expect(Orchestrator::Herdr).to have_received(:agent_start).once
    end

    it "fails the session when the pane never settles at an idle shell" do
      stub_const("#{described_class}::SHELL_POLL_ATTEMPTS", 2)
      stub_successful_launch
      allow(Orchestrator::Herdr).to receive(:pane_process_info).and_return(busy_shell_info)

      expect { described_class.start!(run) }
        .to raise_error(described_class::Error, /never settled at an idle shell/)

      expect(Orchestrator::Herdr).not_to have_received(:agent_start)
      expect(run.run_sessions.sole).to have_attributes(status: "failed", outcome: "failed")
    end

    # Observed live: agent.prompt delivered the prompt but left it unsubmitted
    # in the input box, and the session sat idle holding its slot forever.
    it "nudges the agent with an Enter when the prompt is left unsubmitted" do
      stub_successful_launch(agent_status: "idle")
      allow(Orchestrator::Herdr).to receive(:agent_send_keys)

      described_class.start!(run)

      expect(Orchestrator::Herdr).to have_received(:agent_send_keys).with("w9:p1", [ "Enter" ]).once
    end

    it "does not nudge a claude session that picked the prompt up on its own" do
      stub_successful_launch(agent_status: "working")
      allow(Orchestrator::Herdr).to receive(:agent_send_keys)

      described_class.start!(run)

      expect(Orchestrator::Herdr).not_to have_received(:agent_send_keys)
    end

    it "refuses a run whose worktree was never provisioned" do
      unprovisioned = create_run(prefix: "session-runner-bad", branch_name: nil)

      expect { described_class.start!(unprovisioned) }
        .to raise_error(described_class::Error, /no provisioned worktree/)
      expect(unprovisioned.run_sessions).to be_empty
    end

    # A half-started session would hold a pane and a concurrency slot forever.
    it "closes the herdr workspace and fails the session when the agent never becomes ready" do
      stub_const("#{described_class}::READY_POLL_ATTEMPTS", 2)
      stub_const("#{described_class}::READY_POLL_INTERVAL_SECONDS", 0)
      stub_successful_launch
      allow(Orchestrator::Herdr).to receive(:agent_get).and_return("interactive_ready" => false)
      allow(Orchestrator::Herdr).to receive(:workspace_close)

      expect { described_class.start!(run) }.to raise_error(described_class::Error, /never became ready/)

      expect(Orchestrator::Herdr).to have_received(:workspace_close).with("w9")
      expect(run.run_sessions.sole).to have_attributes(status: "failed", outcome: "failed")
      expect(run.live_session).to be_nil
    end

    it "sends codex its directory-trust Enter, and no other driver one" do
      stub_const("#{described_class}::CODEX_TRUST_PROMPT_GRACE_SECONDS", 0)
      stub_successful_launch
      allow(Orchestrator::Herdr).to receive(:agent_send_keys)

      described_class.start!(run)
      expect(Orchestrator::Herdr).not_to have_received(:agent_send_keys)

      codex_run = create_run(
        prefix: "session-runner-codex", launcher_variant: "codex", status: "launching",
        target_root: Dir.mktmpdir("session-runner-codex"), branch_name: "workflow/codex", worktree_name: "codex-a1b2"
      )
      described_class.start!(codex_run)

      expect(Orchestrator::Herdr).to have_received(:agent_send_keys).with("w9:p1", [ "Enter" ])
    end

    it "launches the model picked for the run and records it on the session" do
      stub_successful_launch
      run.update!(model: "claude-sonnet-5")

      session = described_class.start!(run)

      expect(Orchestrator::Herdr).to have_received(:agent_start)
        .with(hash_including(args: array_including("--model", "claude-sonnet-5")))
      expect(session.model).to eq("claude-sonnet-5")
    end

    it "records the driver default as the session model when none was picked" do
      stub_successful_launch

      session = described_class.start!(run)

      expect(session.model).to eq(Orchestrator::SessionArgs.claude_model)
    end

    it "passes a resume id through to the driver args when one is known" do
      stub_successful_launch

      described_class.start!(run, resume_session_id: "sess-77")

      expect(Orchestrator::Herdr).to have_received(:agent_start)
        .with(hash_including(args: array_including("--resume", "sess-77")))
    end
  end

  describe ".refresh!" do
    it "records herdr's agent status and backfills the CLI session id for later resumes" do
      _run, session = create_run_and_session(run:, prefix: "session-runner")
      allow(described_class).to receive(:process_alive?).and_return(true)
      allow(Orchestrator::Herdr).to receive(:agent_get).and_return(
        "agent_status" => "working", "agent_session" => { "value" => "cli-abc", "kind" => "session_id" }
      )

      described_class.refresh!(session)

      expect(session.reload).to have_attributes(agent_status: "working", cli_session_id: "cli-abc")
      expect(session.last_seen_at).to be_present
    end

    it "fails the session when herdr no longer knows the pane" do
      _run, session = create_run_and_session(run:, prefix: "session-runner")
      allow(Orchestrator::Herdr).to receive(:agent_get).and_raise(Orchestrator::Herdr::Error, "pane_not_found")

      described_class.refresh!(session)

      expect(session.reload).to have_attributes(status: "failed", outcome: "failed", herdr_pane_id: nil)
      # The rest of the workspace (a layout's log tail or dev server) must not
      # outlive the agent pane.
      expect(Orchestrator::Herdr).to have_received(:workspace_close).with("w1")
    end

    # Regression: a session that already reported "done" -- work committed,
    # pushed, maybe merged -- and then lost its pane before the operator
    # closed it is not a failed run. Losing the pane afterward must not
    # overwrite what the session itself already reported.
    it "keeps a session's last reported outcome when its pane disappears afterward" do
      run.update!(status: "awaiting_review")
      _run, session = create_run_and_session(run:, prefix: "session-runner")
      Orchestrator::RunIdleReport.call(run:, session:, outcome: "done", summary: "Merged into main.")
      allow(Orchestrator::Herdr).to receive(:agent_get).and_raise(Orchestrator::Herdr::Error, "pane_not_found")

      described_class.refresh!(session)

      expect(session.reload).to have_attributes(status: "done", outcome: "done", herdr_pane_id: nil)
      expect(session.result).to eq("Merged into main.")
    end

    # Without this, a run whose CLI was quit or crashed would hold its
    # concurrency slot forever: no further report can arrive.
    it "fails the session when the pane is alive but its process is gone" do
      _run, session = create_run_and_session(run:, prefix: "session-runner")
      allow(Orchestrator::Herdr).to receive(:agent_get).and_return("agent_status" => "idle")
      allow(Orchestrator::Herdr).to receive(:workspace_close)
      allow(described_class).to receive(:process_alive?).and_return(false)

      described_class.refresh!(session)

      expect(session.reload).to have_attributes(status: "failed", outcome: "failed")
      expect(session.result).to include("exited without reporting a result")
    end

    # Regression: a transient herdr blip (socket refused, timeout) must not be
    # treated as confirmation the pane is gone -- that once permanently failed
    # a run whose session had already reported "done" and was just sitting
    # idle waiting on the operator. Unreachable must propagate so the caller's
    # own retry-next-minute safety net (RunSessionReconcileJob) applies.
    it "re-raises and leaves the session alone when herdr is merely unreachable" do
      _run, session = create_run_and_session(run:, prefix: "session-runner")
      session.update!(status: "done", outcome: "done", result: "Finished.")
      allow(Orchestrator::Herdr).to receive(:agent_get)
        .and_raise(Orchestrator::Herdr::Unreachable, "herdr is not running")

      expect { described_class.refresh!(session) }.to raise_error(Orchestrator::Herdr::Unreachable)

      expect(session.reload).to have_attributes(status: "done", outcome: "done", ended_at: nil)
    end

    # Same regression, via the process-gone path: the CLI exiting after a
    # "done" report must not clobber that report with the generic message.
    it "keeps a session's last reported outcome when its process exits afterward" do
      run.update!(status: "awaiting_review")
      _run, session = create_run_and_session(run:, prefix: "session-runner")
      Orchestrator::RunIdleReport.call(run:, session:, outcome: "done", summary: "Merged into main.")
      allow(Orchestrator::Herdr).to receive(:agent_get).and_return("agent_status" => "idle")
      allow(Orchestrator::Herdr).to receive(:workspace_close)
      allow(described_class).to receive(:process_alive?).and_return(false)

      described_class.refresh!(session)

      expect(session.reload).to have_attributes(status: "done", outcome: "done")
      expect(session.result).to eq("Merged into main.")
    end

    it "leaves an already-ended session alone" do
      _run, session = create_run_and_session(run:, prefix: "session-runner")
      session.update!(status: "done", outcome: "done", ended_at: Time.current)

      expect(Orchestrator::Herdr).not_to receive(:agent_get)
      described_class.refresh!(session)
    end
  end

  describe ".prompt!" do
    it "delivers text to a live pane" do
      _run, session = create_run_and_session(run:, prefix: "session-runner", status: "blocked")
      allow(Orchestrator::Herdr).to receive(:agent_prompt)

      described_class.prompt!(session, "Use the other migration.")

      expect(Orchestrator::Herdr).to have_received(:agent_prompt).with("w1:p1", "Use the other migration.")
      expect(session.reload.status).to eq("running")
    end

    it "refuses to prompt a session that has ended" do
      _run, session = create_run_and_session(run:, prefix: "session-runner")
      session.update!(status: "done", ended_at: Time.current)

      expect { described_class.prompt!(session, "hello") }.to raise_error(described_class::Error, /not live/)
    end
  end

  describe ".finish!" do
    # An interactive CLI never exits on its own once a turn is over, so
    # "finished" only becomes "process gone" because this kills it.
    it "kills the process group, closes the workspace, and records the outcome" do
      _run, session = create_run_and_session(run:, prefix: "session-runner", pid: 4321)
      allow(Process).to receive(:kill)
      allow(Orchestrator::Herdr).to receive(:workspace_close)

      described_class.finish!(session, outcome: "done", result: "Shipped it.")

      expect(Process).to have_received(:kill).with("SIGTERM", -4321)
      expect(Orchestrator::Herdr).to have_received(:workspace_close).with("w1")
      expect(session.reload).to have_attributes(
        status: "done", outcome: "done", result: "Shipped it.", herdr_pane_id: nil
      )
      expect(session.ended_at).to be_present
    end

    # Regression: "blocked" is both a live *status* (waiting at a question in
    # its own pane) and a terminal *outcome* (gave up, handed the run back).
    # Writing the outcome straight into status left the session looking live,
    # so the run held its concurrency slot forever.
    it "frees the run's slot when a session ends blocked, not only when it ends done" do
      run.update!(status: "running")
      _run, session = create_run_and_session(run:, prefix: "session-runner", pid: 4321)
      allow(Process).to receive(:kill)
      allow(Orchestrator::Herdr).to receive(:workspace_close)
      expect(Orchestrator::RunConcurrency.occupied_run_ids).to include(run.id)

      described_class.finish!(session, outcome: "blocked", result: "Needs a decision.")

      expect(session.reload.outcome).to eq("blocked")
      expect(session).not_to be_live
      expect(run.reload.live_session).to be_nil
      expect(Orchestrator::RunConcurrency.occupied_run_ids).not_to include(run.id)
    end

    it "tolerates a process that is already gone" do
      _run, session = create_run_and_session(run:, prefix: "session-runner", pid: 4321)
      allow(Process).to receive(:kill).and_raise(Errno::ESRCH)
      allow(Orchestrator::Herdr).to receive(:workspace_close)

      expect { described_class.finish!(session, outcome: "failed", result: "gone") }.not_to raise_error
      expect(session.reload.status).to eq("failed")
    end
  end
end

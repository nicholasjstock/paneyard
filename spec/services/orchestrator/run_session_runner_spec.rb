require "rails_helper"

RSpec.describe Orchestrator::RunSessionRunner do
  let(:run) { create_run(prefix: "session-runner", status: "launching", worktree_name: "session-runner-a1b2") }
  let(:worktree) { Dir.mktmpdir("session-runner-worktree") }

  before do
    allow(Orchestrator::Runner::Herdr).to receive(:notify)
    # Every failure path closes the pane's workspace; stubbed here so no
    # example can reach the real socket through it.
    allow(Orchestrator::Runner::Herdr).to receive(:workspace_close)
    # ...and first reads the agent pane's last screen for the failure record.
    allow(Orchestrator::Runner::Herdr).to receive(:pane_read).and_return("")
    # The default layout's nvim pane beside the agent. PATH is stubbed so
    # examples do not depend on whether this machine has nvim installed.
    allow(Orchestrator::Runner::SessionLayout).to receive(:executable_on_path?).with("nvim").and_return(true)
    allow(Orchestrator::Runner::Herdr).to receive(:pane_split)
      .and_return("pane_id" => "w9:p2", "tab_id" => "w9:t1", "workspace_id" => "w9")
    allow(Orchestrator::Runner::Herdr).to receive(:pane_send_input)
    allow(Orchestrator::Runner::Herdr).to receive(:pane_rename)
    allow(Orchestrator::Runner::Herdr).to receive(:tab_rename)
    allow(Orchestrator::Runner::Herdr).to receive(:tab_create)
      .and_return("tab" => { "tab_id" => "w9:t2" }, "root_pane" => { "pane_id" => "w9:p3" })
    stub_const("Orchestrator::Runner::SessionLauncher::SHELL_POLL_INTERVAL_SECONDS", 0)
    stub_const("Orchestrator::Runner::SessionLauncher::PROMPT_SUBMIT_POLL_INTERVAL_SECONDS", 0)
    stub_const("Orchestrator::Runner::SessionLauncher::AGENT_DETECT_POLL_INTERVAL_SECONDS", 0)
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
    # herdr's worktree.create: the run's worktree, opened as its workspace,
    # whose root pane becomes the agent's.
    allow(Orchestrator::Runner.local).to receive(:provision_worktree) do |**arguments|
      launched = false
      { "repository_path" => arguments.fetch(:repository_path), "target_root" => worktree,
        "branch" => arguments.fetch(:branch), "base_sha" => "abc123def4567890", "reused" => false,
        "workspace_id" => "w9", "tab_id" => "w9:t1", "pane_id" => pane_id }
    end
    allow(Orchestrator::Runner::Herdr).to receive(:agent_get)
      .and_return("agent" => "claude", "interactive_ready" => true, "agent_status" => agent_status)
    allow(Orchestrator::Runner::Herdr).to receive(:agent_prompt)
    allow(Orchestrator::Runner::Herdr).to receive(:agent_start) { launched = true; nil }
    allow(Orchestrator::Runner::Herdr).to receive(:pane_process_info) { launched ? running_agent_info : idle_shell_info }
  end

  describe ".start!" do
    it "opens a pane in the worktree, launches the agent, submits the prompt, and records the process group" do
      stub_successful_launch

      session = described_class.start!(run)

      expect(Orchestrator::Runner.local).to have_received(:provision_worktree).with(
        repository_path: run.workspace.repository_path, branch: "paneyard/session-runner-a1b2", base_branch: "main",
        label: "session-runner-a1b2", current_target_root: nil
      )
      expect(run.reload).to have_attributes(target_root: worktree, branch_name: "paneyard/session-runner-a1b2",
        source_root: run.workspace.repository_path, base_sha: "abc123def4567890")
      expect(Orchestrator::Runner::Herdr).to have_received(:agent_start)
        .with(hash_including(kind: "claude", pane_id: "w9:p1"))
      # The prompt is live input, never an argv element.
      expect(Orchestrator::Runner::Herdr).to have_received(:agent_prompt).with("w9:p1", a_string_including(run.task))

      expect(session).to have_attributes(status: "running", pid: 555, herdr_pane_id: "w9:p1", driver: "claude")
      expect(File.read(session.prompt_path)).to include(run.task)
    end

    it "keeps a report the agent made before launch_agent returned" do
      stub_successful_launch
      allow(Orchestrator::Runner.local).to receive(:launch_agent).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap do
          RunSession.where(run:).update_all(status: "done", outcome: "done", result: "Already finished.")
        end
      end

      session = described_class.start!(run)

      expect(session.reload).to have_attributes(status: "done", outcome: "done", pid: 555)
      expect(session.started_at).to be_present
    end

    it "splits nvim opened on the worktree beside the agent by default, and keeps tracking only the agent pane" do
      stub_successful_launch

      session = described_class.start!(run)

      expect(Orchestrator::Runner::Herdr).to have_received(:pane_split).with(
        target_pane_id: "w9:p1", direction: "right", ratio: nil, cwd: worktree, focus: false
      )
      expect(Orchestrator::Runner::Herdr).to have_received(:pane_send_input).with("w9:p2", text: "nvim .", keys: [ "Enter" ])
      expect(Orchestrator::Runner::Herdr).to have_received(:agent_start).with(hash_including(pane_id: "w9:p1"))
      expect(Orchestrator::Runner::Herdr).not_to have_received(:agent_prompt).with("w9:p2", anything)
      expect(session).to have_attributes(status: "running", herdr_pane_id: "w9:p1", herdr_workspace_id: "w9")
    end

    it "launches with just the agent pane when nvim is not on PATH" do
      stub_successful_launch
      allow(Orchestrator::Runner::SessionLayout).to receive(:executable_on_path?).with("nvim").and_return(false)

      session = described_class.start!(run)

      expect(Orchestrator::Runner::Herdr).not_to have_received(:pane_split)
      expect(Orchestrator::Runner::Herdr).not_to have_received(:pane_send_input)
      expect(session).to have_attributes(status: "running", herdr_pane_id: "w9:p1")
    end

    it "launches with just the agent pane when herdr refuses the split" do
      stub_successful_launch
      allow(Orchestrator::Runner::Herdr).to receive(:pane_split).and_raise(Orchestrator::Runner::Herdr::Error, "no such pane")

      session = described_class.start!(run)

      expect(Orchestrator::Runner::Herdr).not_to have_received(:pane_send_input)
      expect(Orchestrator::Runner::Herdr).not_to have_received(:workspace_close)
      expect(session).to have_attributes(status: "running", pid: 555, herdr_pane_id: "w9:p1")
    end

    it "opens the workspace's own layout in the worktree's workspace: extra tabs and splits, the agent still tracked" do
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
      allow(Orchestrator::Runner::Herdr).to receive(:pane_split)
        .and_return("pane_id" => "w9:p4", "tab_id" => "w9:t2", "workspace_id" => "w9")

      session = described_class.start!(run)

      expect(Orchestrator::Runner::Herdr).to have_received(:tab_rename).with("w9:t1", "main")
      expect(Orchestrator::Runner::Herdr).to have_received(:tab_create)
        .with(workspace_id: "w9", label: "logs", cwd: worktree, focus: false)
      expect(Orchestrator::Runner::Herdr).to have_received(:pane_send_input)
        .with("w9:p3", text: "tail -f log/development.log", keys: [ "Enter" ])
      expect(Orchestrator::Runner::Herdr).to have_received(:pane_split).with(
        hash_including(target_pane_id: "w9:p3", direction: "down", focus: false)
      )
      expect(Orchestrator::Runner::Herdr).to have_received(:pane_send_input)
        .with("w9:p4", text: "tail -f log/test.log", keys: [ "Enter" ])
      expect(session).to have_attributes(status: "running", herdr_pane_id: "w9:p1", herdr_tab_id: "w9:t1")
    end

    it "launches the agent even when a layout tab cannot be opened" do
      stub_successful_launch
      run.workspace.update!(layout: "tabs:\n  - panes: [agent]\n  - panes: [{ name: logs, command: tail -f x }]\n")
      allow(Orchestrator::Runner::Herdr).to receive(:tab_create).and_raise(Orchestrator::Runner::Herdr::Error, "boom")

      session = described_class.start!(run)

      expect(Orchestrator::Runner::Herdr).not_to have_received(:workspace_close)
      expect(session).to have_attributes(status: "running", herdr_pane_id: "w9:p1")
    end

    it "still launches the agent when nvim cannot be typed into the split pane" do
      stub_successful_launch
      allow(Orchestrator::Runner::Herdr).to receive(:pane_send_input).and_raise(Orchestrator::Runner::Herdr::Unreachable, "timed out")

      session = described_class.start!(run)

      expect(Orchestrator::Runner::Herdr).to have_received(:agent_start).once
      expect(session).to have_attributes(status: "running", herdr_pane_id: "w9:p1")
    end

    # A fresh pane's shell runs the operator's rc files (pyenv, starship, git)
    # before it is idle, and herdr rejects agent.start for the whole of that
    # window. Rails writes the session row between workspace.create and
    # agent.start, which put the launch squarely inside it.
    it "waits for the pane's shell to go idle before launching the agent" do
      stub_successful_launch
      allow(Orchestrator::Runner::Herdr).to receive(:pane_process_info).and_return(
        busy_shell_info, busy_shell_info,
        *Array.new(Orchestrator::Runner::SessionLauncher::SHELL_STABLE_SAMPLES) { idle_shell_info },
        running_agent_info
      )

      described_class.start!(run)

      expect(Orchestrator::Runner::Herdr).to have_received(:agent_start).once
    end

    # A single idle sample can be a gap between two rc files rather than the
    # end of startup.
    it "requires consecutive idle samples rather than one" do
      stub_successful_launch
      allow(Orchestrator::Runner::Herdr).to receive(:pane_process_info).and_return(
        idle_shell_info, busy_shell_info,
        *Array.new(Orchestrator::Runner::SessionLauncher::SHELL_STABLE_SAMPLES) { idle_shell_info },
        running_agent_info
      )

      described_class.start!(run)

      expect(Orchestrator::Runner::Herdr).to have_received(:agent_start).once
    end

    # The poll cannot close the gap between its last sample and agent.start.
    it "retries the launch when herdr still reports the pane is not an available shell" do
      stub_successful_launch
      attempts = 0
      launched = false
      allow(Orchestrator::Runner::Herdr).to receive(:agent_start) do
        attempts += 1
        raise Orchestrator::Runner::Herdr::Error, "agent target pane w9:p1 is not an available shell" if attempts == 1

        launched = true
        nil
      end
      allow(Orchestrator::Runner::Herdr).to receive(:pane_process_info) { launched ? running_agent_info : idle_shell_info }

      session = described_class.start!(run)

      expect(Orchestrator::Runner::Herdr).to have_received(:agent_start).twice
      expect(session.status).to eq("running")
    end

    it "gives up and fails the session when every launch attempt is rejected" do
      stub_successful_launch
      allow(Orchestrator::Runner::Herdr).to receive(:agent_start)
        .and_raise(Orchestrator::Runner::Herdr::Error, "agent target pane w9:p1 is not an available shell")
      allow(Orchestrator::Runner::Herdr).to receive(:pane_process_info).and_return(idle_shell_info)

      expect { described_class.start!(run) }.to raise_error(Orchestrator::Runner::Error, /not an available shell/)

      expect(Orchestrator::Runner::Herdr).to have_received(:agent_start).exactly(Orchestrator::Runner::SessionLauncher::AGENT_START_ATTEMPTS).times
      expect(Orchestrator::Runner::Herdr).to have_received(:workspace_close).with("w9")
      expect(run.run_sessions.sole).to have_attributes(status: "failed", outcome: "failed")
    end

    # An unrelated herdr failure must not be retried as if it were the race.
    it "does not retry a launch that failed for any other reason" do
      stub_successful_launch
      allow(Orchestrator::Runner::Herdr).to receive(:agent_start)
        .and_raise(Orchestrator::Runner::Herdr::Error, "unknown agent kind")

      expect { described_class.start!(run) }.to raise_error(Orchestrator::Runner::Error, /unknown agent kind/)

      expect(Orchestrator::Runner::Herdr).to have_received(:agent_start).once
    end

    it "fails the session when the pane never settles at an idle shell" do
      stub_const("Orchestrator::Runner::SessionLauncher::SHELL_POLL_ATTEMPTS", 2)
      stub_successful_launch
      allow(Orchestrator::Runner::Herdr).to receive(:pane_process_info).and_return(busy_shell_info)

      expect { described_class.start!(run) }
        .to raise_error(Orchestrator::Runner::LaunchError, /never settled at an idle shell/)

      expect(Orchestrator::Runner::Herdr).not_to have_received(:agent_start)
      expect(run.run_sessions.sole).to have_attributes(status: "failed", outcome: "failed")
    end

    # Observed live: agent.prompt delivered the prompt but left it unsubmitted
    # in the input box, and the session sat idle holding its slot forever;
    # and on run-20260929-194456-3ec1 the first Enter was ignored too.
    it "nudges the agent with bounded Enters when the prompt is left unsubmitted, and still starts the run" do
      stub_successful_launch(agent_status: "idle")
      allow(Orchestrator::Runner::Herdr).to receive(:agent_send_keys)
      allow(Orchestrator::Runner::Herdr).to receive(:notify)

      session = described_class.start!(run)

      expect(Orchestrator::Runner::Herdr).to have_received(:agent_send_keys).with("w9:p1", [ "Enter" ])
        .exactly(Orchestrator::Runner::SessionLauncher::PROMPT_SUBMIT_RETRY_WINDOWS.size).times
      expect(session.reload).to have_attributes(status: "running", pid: 555)
    end

    it "does not nudge a claude session that picked the prompt up on its own" do
      stub_successful_launch(agent_status: "working")
      allow(Orchestrator::Runner::Herdr).to receive(:agent_send_keys)

      described_class.start!(run)

      expect(Orchestrator::Runner::Herdr).not_to have_received(:agent_send_keys)
    end

    it "fails the session, with nothing to close, when herdr cannot make the worktree" do
      allow(Orchestrator::Runner.local).to receive(:provision_worktree)
        .and_raise(Orchestrator::Runner::Error, "Base branch `gone`: there is no local branch `gone`")

      expect { described_class.start!(run) }.to raise_error(Orchestrator::Runner::Error, /no local branch/)
      expect(run.latest_session).to have_attributes(status: "failed", herdr_workspace_id: nil, result: include("no local branch"))
      expect(Orchestrator::Runner::Herdr).not_to have_received(:workspace_close)
    end

    # A half-started session would hold a pane and a concurrency slot forever.
    it "closes the herdr workspace and fails the session when the agent never becomes ready" do
      stub_const("Orchestrator::Runner::SessionLauncher::READY_POLL_ATTEMPTS", 2)
      stub_const("Orchestrator::Runner::SessionLauncher::READY_POLL_INTERVAL_SECONDS", 0)
      stub_successful_launch
      allow(Orchestrator::Runner::Herdr).to receive(:agent_get).and_return("agent" => "claude", "interactive_ready" => false)
      allow(Orchestrator::Runner::Herdr).to receive(:workspace_close)

      expect { described_class.start!(run) }.to raise_error(Orchestrator::Runner::LaunchError, /never became ready/)

      expect(Orchestrator::Runner::Herdr).to have_received(:workspace_close).with("w9")
      expect(run.run_sessions.sole).to have_attributes(status: "failed", outcome: "failed")
      expect(run.live_session).to be_nil
    end

    # The workspace is closed on failure, which destroys the pane -- so what
    # the pane showed (a shell error, the CLI's exit message) is read first.
    it "keeps the agent pane's last screen in the session result when the launch fails" do
      stub_const("Orchestrator::Runner::SessionLauncher::READY_POLL_ATTEMPTS", 1)
      stub_const("Orchestrator::Runner::SessionLauncher::READY_POLL_INTERVAL_SECONDS", 0)
      stub_successful_launch
      allow(Orchestrator::Runner::Herdr).to receive(:agent_get).and_return("agent" => "claude", "interactive_ready" => false)
      allow(Orchestrator::Runner::Herdr).to receive(:pane_read).and_return("~/worktree $ claude --model x\nError: cwd was deleted\n")

      expect { described_class.start!(run) }.to raise_error(Orchestrator::Runner::LaunchError, /never became ready/)

      expect(Orchestrator::Runner::Herdr).to have_received(:pane_read)
        .with("w9:p1", source: "recent_unwrapped", lines: described_class::LAUNCH_SCREEN_LINES).ordered
      expect(Orchestrator::Runner::Herdr).to have_received(:workspace_close).with("w9").ordered
      expect(run.run_sessions.sole.result).to eq(
        "herdr agent in pane w9:p1 never became ready\n\n" \
        "--- Last screen of agent pane w9:p1 ---\n~/worktree $ claude --model x\nError: cwd was deleted"
      )
    end

    it "names claude's folder-trust prompt when that is where the launch stopped" do
      stub_const("Orchestrator::Runner::SessionLauncher::READY_POLL_ATTEMPTS", 1)
      stub_const("Orchestrator::Runner::SessionLauncher::READY_POLL_INTERVAL_SECONDS", 0)
      stub_successful_launch
      allow(Orchestrator::Runner::Herdr).to receive(:agent_get).and_return("agent" => "claude", "interactive_ready" => false)
      allow(Orchestrator::Runner::Herdr).to receive(:pane_read).and_return("❯ No, exit\n  Yes, I trust this folder\n")

      expect { described_class.start!(run) }.to raise_error(Orchestrator::Runner::LaunchError)

      expect(run.run_sessions.sole.result).to include("claude stopped at its folder-trust prompt although Paneyard marks each worktree as trusted")
    end

    it "keeps only the tail of a long pane screen" do
      stub_const("#{described_class}::LAUNCH_SCREEN_MAX_CHARS", 10)
      stub_successful_launch
      allow(Orchestrator::Runner::Herdr).to receive(:agent_start).and_raise(Orchestrator::Runner::Herdr::Error, "unknown agent kind")
      allow(Orchestrator::Runner::Herdr).to receive(:pane_read).and_return("#{'x' * 50}0123456789")

      expect { described_class.start!(run) }.to raise_error(Orchestrator::Runner::Error)

      expect(run.run_sessions.sole.result).to end_with("---\n[...]\n0123456789")
    end

    it "never lets a failed pane read mask the launch error" do
      stub_successful_launch
      allow(Orchestrator::Runner::Herdr).to receive(:agent_start).and_raise(Orchestrator::Runner::Herdr::Error, "unknown agent kind")
      allow(Orchestrator::Runner::Herdr).to receive(:pane_read).and_raise(Orchestrator::Runner::Herdr::Unreachable, "timed out")

      expect { described_class.start!(run) }.to raise_error(Orchestrator::Runner::Error, "unknown agent kind")

      expect(Orchestrator::Runner::Herdr).to have_received(:workspace_close).with("w9")
      expect(run.run_sessions.sole).to have_attributes(status: "failed", result: "unknown agent kind")

      allow(Orchestrator::Runner::Herdr).to receive(:pane_read).and_raise(KeyError, "read")
      expect { described_class.start!(run) }.to raise_error(Orchestrator::Runner::Error, "unknown agent kind")
    end

    # Observed live: agent.start returned ok, herdr never saw claude start, and
    # 30 s later agent.get only said "agent target ... not found".
    it "fails fast with a plain message when herdr never detects the agent starting" do
      stub_const("Orchestrator::Runner::SessionLauncher::AGENT_DETECT_POLL_ATTEMPTS", 3)
      stub_successful_launch
      allow(Orchestrator::Runner::Herdr).to receive(:agent_get)
        .and_return("agent" => nil, "launch_pending" => true, "interactive_ready" => false, "agent_status" => "unknown")

      expect { described_class.start!(run) }.to raise_error(
        Orchestrator::Runner::LaunchError, /\Aherdr never detected claude starting in pane w9:p1 after \d+s: /
      )

      expect(Orchestrator::Runner::Herdr).to have_received(:agent_get).exactly(3).times
      # Never a second launch: it could type a command line into a live CLI.
      expect(Orchestrator::Runner::Herdr).to have_received(:agent_start).once
      expect(Orchestrator::Runner::Herdr).not_to have_received(:agent_prompt)
      expect(run.run_sessions.sole).to have_attributes(status: "failed", outcome: "failed")
      expect(run.run_sessions.sole.result).to start_with("herdr never detected claude starting")
    end

    it "explains herdr's 'agent target not found' while waiting for the agent to start" do
      stub_successful_launch
      allow(Orchestrator::Runner::Herdr).to receive(:agent_get)
        .and_raise(Orchestrator::Runner::Herdr::Error, "agent target w9:p1 not found")

      expect { described_class.start!(run) }.to raise_error(
        Orchestrator::Runner::LaunchError, /herdr stopped tracking the claude launch in pane w9:p1 while waiting for it to start/
      )
    end

    it "explains herdr's 'agent target not found' while waiting for the agent to become ready" do
      stub_successful_launch
      calls = 0
      allow(Orchestrator::Runner::Herdr).to receive(:agent_get) do
        calls += 1
        raise Orchestrator::Runner::Herdr::Error, "agent target w9:p1 not found" if calls > 2

        { "agent" => "claude", "interactive_ready" => false }
      end

      expect { described_class.start!(run) }.to raise_error(
        Orchestrator::Runner::LaunchError,
        /stopped tracking the claude launch in pane w9:p1 while waiting for it to become ready \(herdr: agent target/
      )
      expect(run.run_sessions.sole.result).to include("never started or exited")
    end

    it "does not reword a herdr error that is not a lost agent target" do
      stub_successful_launch
      allow(Orchestrator::Runner::Herdr).to receive(:agent_get).and_raise(Orchestrator::Runner::Herdr::Unreachable, "herdr timed out")

      expect { described_class.start!(run) }.to raise_error(Orchestrator::Runner::Unreachable, "herdr timed out")
    end

    it "sends codex its directory-trust Enter, and no other driver one" do
      stub_const("Orchestrator::Runner::SessionLauncher::CODEX_TRUST_PROMPT_GRACE_SECONDS", 0)
      stub_successful_launch
      allow(Orchestrator::Runner::Herdr).to receive(:agent_send_keys)

      described_class.start!(run)
      expect(Orchestrator::Runner::Herdr).not_to have_received(:agent_send_keys)

      codex_run = create_run(
        prefix: "session-runner-codex", launcher_variant: "codex", status: "launching",
        target_root: Dir.mktmpdir("session-runner-codex"), branch_name: "paneyard/codex", worktree_name: "codex-a1b2"
      )
      described_class.start!(codex_run)

      expect(Orchestrator::Runner::Herdr).to have_received(:agent_send_keys).with("w9:p1", [ "Enter" ])
    end

    it "launches the model picked for the run and records it on the session" do
      stub_successful_launch
      run.update!(model: "claude-sonnet-5")

      session = described_class.start!(run)

      expect(Orchestrator::Runner::Herdr).to have_received(:agent_start)
        .with(hash_including(args: array_including("--model", "claude-sonnet-5")))
      expect(session.model).to eq("claude-sonnet-5")
    end

    it "records the driver default as the session model when none was picked" do
      stub_successful_launch

      session = described_class.start!(run)

      expect(session.model).to eq(Orchestrator::DefaultModels.for("claude"))
      expect(Orchestrator::Runner::Herdr).to have_received(:agent_start)
        .with(hash_including(args: array_including("--model", Orchestrator::DefaultModels.for("claude"))))
    end

    it "gives no pane an environment of its own" do
      stub_successful_launch

      described_class.start!(run)

      expect(Orchestrator::Runner::Herdr).to have_received(:pane_split).with(hash_excluding(:env))
    end

    it "passes a resume id through to the driver args when one is known" do
      stub_successful_launch

      described_class.start!(run, resume_session_id: "sess-77")

      expect(Orchestrator::Runner::Herdr).to have_received(:agent_start)
        .with(hash_including(args: array_including("--resume", "sess-77")))
    end
  end

  describe ".refresh!" do
    it "records herdr's agent status and backfills the CLI session id for later resumes" do
      _run, session = create_run_and_session(run:, prefix: "session-runner")
      allow(described_class).to receive(:process_alive?).and_return(true)
      allow(Orchestrator::Runner::Herdr).to receive(:agent_get).and_return(
        "agent_status" => "working", "agent_session" => { "value" => "cli-abc", "kind" => "session_id" }
      )

      described_class.refresh!(session)

      expect(session.reload).to have_attributes(agent_status: "working", cli_session_id: "cli-abc")
      expect(session.last_seen_at).to be_present
    end

    it "fails the session when herdr no longer knows the pane" do
      _run, session = create_run_and_session(run:, prefix: "session-runner")
      allow(Orchestrator::Runner::Herdr).to receive(:agent_get).and_raise(Orchestrator::Runner::Herdr::Error, "pane_not_found")

      described_class.refresh!(session)

      expect(session.reload).to have_attributes(status: "failed", outcome: "failed", herdr_pane_id: nil)
      # The rest of the workspace (a layout's log tail or dev server) must not
      # outlive the agent pane.
      expect(Orchestrator::Runner::Herdr).to have_received(:workspace_close).with("w1")
    end

    # Regression: a session that already reported "done" -- work committed,
    # pushed, maybe merged -- and then lost its pane before the operator
    # closed it is not a failed run. Losing the pane afterward must not
    # overwrite what the session itself already reported.
    it "keeps a session's last reported outcome when its pane disappears afterward" do
      run.update!(status: "awaiting_review")
      _run, session = create_run_and_session(run:, prefix: "session-runner")
      Orchestrator::RunIdleReport.call(run:, session:, outcome: "done", summary: "Merged into main.")
      allow(Orchestrator::Runner::Herdr).to receive(:agent_get).and_raise(Orchestrator::Runner::Herdr::Error, "pane_not_found")

      described_class.refresh!(session)

      expect(session.reload).to have_attributes(status: "done", outcome: "done", herdr_pane_id: nil)
      expect(session.result).to eq("Merged into main.")
    end

    # Without this, a run whose CLI was quit or crashed would hold its
    # concurrency slot forever: no further report can arrive.
    it "fails the session when the pane is alive but its process is gone" do
      _run, session = create_run_and_session(run:, prefix: "session-runner")
      allow(Orchestrator::Runner::Herdr).to receive(:agent_get).and_return("agent_status" => "idle")
      allow(Orchestrator::Runner::Herdr).to receive(:workspace_close)
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
      allow(Orchestrator::Runner::Herdr).to receive(:agent_get)
        .and_raise(Orchestrator::Runner::Herdr::Unreachable, "herdr is not running")

      expect { described_class.refresh!(session) }.to raise_error(Orchestrator::Runner::Unreachable)

      expect(session.reload).to have_attributes(status: "done", outcome: "done", ended_at: nil)
    end

    # Same regression, via the process-gone path: the CLI exiting after a
    # "done" report must not clobber that report with the generic message.
    it "keeps a session's last reported outcome when its process exits afterward" do
      run.update!(status: "awaiting_review")
      _run, session = create_run_and_session(run:, prefix: "session-runner")
      Orchestrator::RunIdleReport.call(run:, session:, outcome: "done", summary: "Merged into main.")
      allow(Orchestrator::Runner::Herdr).to receive(:agent_get).and_return("agent_status" => "idle")
      allow(Orchestrator::Runner::Herdr).to receive(:workspace_close)
      allow(described_class).to receive(:process_alive?).and_return(false)

      described_class.refresh!(session)

      expect(session.reload).to have_attributes(status: "done", outcome: "done")
      expect(session.result).to eq("Merged into main.")
    end

    # Regression (run-20260927-075528-47b3): before agent.start herdr has no
    # agent in the pane and agent.get says "not found". The reconcile tick
    # that landed in that window marked the session lost, completed the run
    # and removed its clean worktree, and start! then launched claude into a
    # deleted directory.
    it "leaves a session that start! is still launching to start!" do
      _run, session = create_run_and_session(run:, prefix: "session-runner", status: "starting", started_at: nil)

      expect(Orchestrator::Runner::Herdr).not_to receive(:agent_get)
      described_class.refresh!(session)

      expect(session.reload).to have_attributes(status: "starting", ended_at: nil, herdr_pane_id: "w1:p1")
    end

    # ...but a worker that died mid-launch must not hold a slot forever.
    it "reconciles a session stuck starting long past any real launch" do
      _run, session = create_run_and_session(run:, prefix: "session-runner", status: "starting", started_at: nil)
      session.update!(created_at: (described_class::STARTING_GRACE + 1.minute).ago)
      allow(Orchestrator::Runner::Herdr).to receive(:agent_get)
        .and_raise(Orchestrator::Runner::Herdr::Error, "agent target w1:p1 not found")

      described_class.refresh!(session)

      expect(session.reload).to have_attributes(status: "failed", outcome: "failed", herdr_pane_id: nil)
    end

    it "leaves an already-ended session alone" do
      _run, session = create_run_and_session(run:, prefix: "session-runner")
      session.update!(status: "done", outcome: "done", ended_at: Time.current)

      expect(Orchestrator::Runner::Herdr).not_to receive(:agent_get)
      described_class.refresh!(session)
    end
  end

  describe ".prompt!" do
    it "delivers text to a live pane" do
      _run, session = create_run_and_session(run:, prefix: "session-runner", status: "blocked")
      allow(Orchestrator::Runner::Herdr).to receive(:agent_prompt)

      described_class.prompt!(session, "Use the other migration.")

      expect(Orchestrator::Runner::Herdr).to have_received(:agent_prompt).with("w1:p1", "Use the other migration.")
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
      allow(Orchestrator::Runner::Herdr).to receive(:workspace_close)

      described_class.finish!(session, outcome: "done", result: "Shipped it.")

      expect(Process).to have_received(:kill).with("SIGTERM", -4321)
      expect(Orchestrator::Runner::Herdr).to have_received(:workspace_close).with("w1")
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
      allow(Orchestrator::Runner::Herdr).to receive(:workspace_close)
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
      allow(Orchestrator::Runner::Herdr).to receive(:workspace_close)

      expect { described_class.finish!(session, outcome: "failed", result: "gone") }.not_to raise_error
      expect(session.reload.status).to eq("failed")
    end
  end
end

require "rails_helper"

RSpec.describe Orchestrator::SessionReopen do
  let(:runner) { Orchestrator::Runner.local }
  let(:workspace) { create_workspace(prefix: "reopen") }

  # A run whose session was closed: worktree and branch recorded, as
  # GitWorktree.provision! left them.
  def closed_run(status: "completed", **attributes)
    run = create_run(workspace:, prefix: "reopen", status:, worktree_name: "fix-it-a1b2", branch_name: "paneyard/fix-it-a1b2",
      source_root: workspace.repository_path, target_root: "/worktrees/fix-it-a1b2", base_sha: "abc123", stopped_at: 1.minute.ago,
      **attributes)
    run.run_sessions.create!(driver: "claude", status: "done", outcome: "done", ended_at: 1.minute.ago, cli_session_id: "conv-1")
    run
  end

  def stub_worktree(registered:, branch: true)
    allow(runner).to receive(:worktree_registered?).and_return(registered)
    allow(runner).to receive(:branch_exists?).and_return(branch)
  end

  describe ".call" do
    it "queues a run whose worktree was kept, to reopen it there, and lets the dispatcher start it" do
      run = closed_run(launch_error: "old")
      stub_worktree(registered: true)

      reopened = nil
      expect { reopened = described_class.call(run) }.to have_enqueued_job(RunDispatchJob)

      expect(reopened).to eq(worktree: "kept")
      expect(run.reload).to have_attributes(status: "queued", stopped_at: nil, launch_error: nil)
      expect(runner).to have_received(:worktree_registered?)
        .with(repository_path: workspace.repository_path, path: "/worktrees/fix-it-a1b2")
      # Queued, not launching: it takes a slot only when the dispatcher has one.
      expect(Orchestrator::RunConcurrency.in_flight).to eq(0)
    end

    it "queues a run whose worktree was removed, to make it again from its branch" do
      run = closed_run(status: "failed")
      stub_worktree(registered: false, branch: true)

      expect(described_class.call(run)).to eq(worktree: "recreated")
      expect(runner).to have_received(:branch_exists?).with(repository_path: workspace.repository_path, branch: "paneyard/fix-it-a1b2")
      expect(run.reload.status).to eq("queued")
    end

    it "refuses a run whose worktree and branch are both gone, and leaves it as it was" do
      run = closed_run(status: "stopped")
      stub_worktree(registered: false, branch: false)

      expect { described_class.call(run) }
        .to raise_error(described_class::NotReopenable, /branch `paneyard\/fix-it-a1b2` no longer exists/)
      expect(run.reload.status).to eq("stopped")
    end

    it "queues a run whose launch failed before it had a worktree, to start it from its base branch" do
      run = create_run(workspace:, prefix: "reopen", status: "failed", launch_error: "herdr was not running")
      run.run_sessions.create!(driver: "claude", status: "failed", outcome: "failed", ended_at: Time.current)
      allow(runner).to receive(:base_branch_problem).and_return(nil)

      expect(described_class.call(run)).to eq(worktree: "new")
      expect(runner).to have_received(:base_branch_problem).with(repository_path: workspace.repository_path, branch: "main")
    end

    it "refuses a run that never got a worktree when its base branch is gone" do
      run = create_run(workspace:, prefix: "reopen", status: "failed")
      allow(runner).to receive(:base_branch_problem).and_return("code" => "base_branch_missing", "message" => "no local branch `main`")

      expect { described_class.call(run) }.to raise_error(described_class::NotReopenable, /never got a worktree.*no local branch/)
    end

    it "refuses a run that still has a live session" do
      run, _session = create_run_and_session(prefix: "reopen-live", status: "running")
      run.update!(status: "awaiting_review")

      expect { described_class.call(run) }.to raise_error(described_class::NotReopenable, /still has a live session/)
    end

    it "refuses a run that is already queued or starting" do
      run = closed_run(status: "queued")

      expect { described_class.call(run) }.to raise_error(described_class::NotReopenable, /already queued/)
    end

    it "refuses, with the reason, when the runner cannot check the worktree" do
      run = closed_run
      allow(runner).to receive(:worktree_registered?).and_raise(Orchestrator::Runner::Error, "git exploded")

      expect { described_class.call(run) }.to raise_error(described_class::NotReopenable, /git exploded/)
    end

    it "does not reopen a run that changed underneath it" do
      run = closed_run
      stub_worktree(registered: true)
      Run.where(id: run.id).update_all(status: "queued")

      expect { described_class.call(run) }.to raise_error(described_class::NotReopenable, /changed while/)
    end
  end

  describe ".problem" do
    it "is nil when the run can be reopened, and why not otherwise" do
      run = closed_run
      stub_worktree(registered: false, branch: true)
      expect(described_class.problem(run)).to be_nil

      stub_worktree(registered: false, branch: false)
      expect(described_class.problem(run)).to include("no longer exists")
    end
  end

  describe ".launch_plan" do
    let(:run) { closed_run }

    it "resumes the previous conversation when the worktree is where it ran" do
      plan = described_class.launch_plan(run, previous: run.latest_session, previous_root: "/worktrees/fix-it-a1b2")

      expect(plan.fetch(:resume)).to include(session_id: "conv-1")
      expect(plan.dig(:resume, :prompt)).to include("reopened run #{run.run_id}", "report_idle", "/worktrees/fix-it-a1b2")
      # Kept for falling back on, should the resumed CLI not come up.
      expect(plan.fetch(:prompt)).to include("# Reopened", run.task)
    end

    it "starts fresh, with the task and the newest report, when the conversation id was never recorded" do
      run.latest_session.update!(cli_session_id: nil)
      run.checkpoints.create!(run_session: run.latest_session, outcome: "blocked", summary: "Which table?", created_at: 2.minutes.ago)
      run.checkpoints.create!(run_session: run.latest_session, outcome: "done", summary: "## Dropped the table")

      plan = described_class.launch_plan(run.reload, previous: run.latest_session, previous_root: "/worktrees/fix-it-a1b2")

      expect(plan[:resume]).to be_nil
      expect(plan.fetch(:prompt)).to include("# Reopened", "`done`", "## Dropped the table", "# Task", run.task,
        "git log main..HEAD", "report_idle")
      expect(plan.fetch(:prompt)).not_to include("Which table?")
    end

    it "starts fresh when the worktree came back somewhere else, since the CLI keys conversations by directory" do
      plan = described_class.launch_plan(run, previous: run.latest_session, previous_root: "/old/place/fix-it-a1b2")

      expect(plan[:resume]).to be_nil
      expect(plan.fetch(:prompt)).to include("It never reported.")
    end
  end
end

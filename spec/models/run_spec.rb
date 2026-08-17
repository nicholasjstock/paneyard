require "rails_helper"

RSpec.describe Run, type: :model do
  describe "sessions" do
    it "exposes only the live session as #live_session, and the newest as #latest_session" do
      run, first = create_run_and_session(prefix: "run-sessions")
      first.update!(status: "done", outcome: "done", ended_at: Time.current)
      _run, second = create_run_and_session(run:, prefix: "run-sessions")

      expect(run.live_session).to eq(second)
      expect(run.latest_session).to eq(second)

      second.update!(status: "closed", ended_at: Time.current)
      expect(run.reload.live_session).to be_nil
      expect(run.latest_session).to eq(second)
    end

    it "refuses a second live session for the same run, so one run can never hold two slots" do
      run, _session = create_run_and_session(prefix: "run-sessions")

      expect do
        create_run_and_session(run:, prefix: "run-sessions")
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "#publication_retryable?" do
    # worktree_name is assigned eagerly at run creation (RunsController#create),
    # before StartRunSessionJob ever attempts GitWorktree.provision! -- a run
    # whose provisioning failed (e.g. a dirty source checkout) keeps that
    # proposed name with no real worktree behind it. branch_name is only ever
    # set once provisioning actually succeeds, so it's the real signal.
    it "is false for a run whose worktree was never actually provisioned, even though worktree_name is set" do
      run = create_run(
        prefix: "retry-unprovisioned", status: "failed",
        worktree_name: "never-provisioned-a1b2", branch_name: nil, publication_status: "failed"
      )

      expect(run.publication_retryable?).to be(false)
    end

    it "is true for a genuinely provisioned run that failed publication" do
      run = create_run(
        prefix: "retry-provisioned", status: "failed",
        worktree_name: "provisioned-a1b2", branch_name: "workflow/provisioned-a1b2", publication_status: "failed"
      )

      expect(run.publication_retryable?).to be(true)
    end
  end
end

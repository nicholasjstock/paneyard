require "rails_helper"

RSpec.describe Orchestrator::PullRequestResume do
  let(:run) do
    create_run(
      prefix: "pr-resume", status: "awaiting_review",
      worktree_name: "pr-resume-a1b2", branch_name: "workflow/pr-resume-a1b2",
      pull_request_url: "https://github.com/example/repo/pull/7",
      publication_status: "awaiting_approval"
    )
  end

  def comment(id:, body: "Please also update the changelog.", login: "reviewer")
    { "id" => id, "body" => body, "user" => { "login" => login } }
  end

  describe ".resume!" do
    # The whole reason the question protocol could go: a reviewer's comment is
    # just a prompt, and there is a live session to say it to.
    it "types a reviewer's comment straight into the live session" do
      _run, session = create_run_and_session(run:, prefix: "pr-resume")
      allow(Orchestrator::RunSessionRunner).to receive(:prompt!)

      expect(described_class.resume!(run, comment(id: 101))).to eq(:prompted)

      expect(Orchestrator::RunSessionRunner).to have_received(:prompt!)
        .with(session, a_string_including("Please also update the changelog."))
      expect(Orchestrator::RunSessionRunner).to have_received(:prompt!)
        .with(session, a_string_including("reviewer"))
      expect(run.reload.last_pull_request_comment_id).to eq("101")
    end

    # A closed session's CLI transcript still exists; resuming it keeps
    # everything the agent learned building the branch in the first place.
    it "reopens a closed session on the same worktree, resuming the CLI conversation" do
      _run, previous = create_run_and_session(run:, prefix: "pr-resume")
      previous.update!(status: "done", outcome: "done", ended_at: Time.current, cli_session_id: "cli-77")
      allow(Orchestrator::GitWorktree).to receive(:restore!)
      allow(Orchestrator::RunSessionRunner).to receive(:start!)

      expect(described_class.resume!(run, comment(id: 102))).to eq(:reopened)

      expect(Orchestrator::RunSessionRunner).to have_received(:start!)
        .with(run, hash_including(resume_session_id: "cli-77"))
      expect(run.reload.status).to eq("running")
    end

    # Closing the session may have reclaimed the worktree (its work was
    # already pushed), so it has to be checked back out before a session can
    # start in it.
    it "restores the run's worktree before reopening a session in it" do
      _run, previous = create_run_and_session(run:, prefix: "pr-resume")
      previous.update!(status: "done", outcome: "done", ended_at: Time.current)
      allow(Orchestrator::GitWorktree).to receive(:restore!)
      allow(Orchestrator::RunSessionRunner).to receive(:start!)

      described_class.resume!(run, comment(id: 104))

      expect(Orchestrator::GitWorktree).to have_received(:restore!).with(run).ordered
      expect(Orchestrator::RunSessionRunner).to have_received(:start!).ordered
    end

    it "puts the run back to awaiting_review if its worktree cannot be restored" do
      _run, previous = create_run_and_session(run:, prefix: "pr-resume")
      previous.update!(status: "closed", ended_at: Time.current)
      allow(Orchestrator::GitWorktree).to receive(:restore!)
        .and_raise(Orchestrator::GitWorktree::Error, "branch is gone")
      allow(Orchestrator::RunSessionRunner).to receive(:start!)

      expect { described_class.resume!(run, comment(id: 105)) }
        .to raise_error(described_class::Error, /branch is gone/)
      expect(Orchestrator::RunSessionRunner).not_to have_received(:start!)
      expect(run.reload.status).to eq("awaiting_review")
    end

    it "puts the run back to awaiting_review if a session cannot be reopened" do
      _run, previous = create_run_and_session(run:, prefix: "pr-resume")
      previous.update!(status: "closed", ended_at: Time.current)
      allow(Orchestrator::GitWorktree).to receive(:restore!)
      allow(Orchestrator::RunSessionRunner).to receive(:start!)
        .and_raise(Orchestrator::Herdr::Error, "herdr is not running")

      expect { described_class.resume!(run, comment(id: 103)) }
        .to raise_error(described_class::Error, /Could not reopen a session/)
      expect(run.reload.status).to eq("awaiting_review")
    end

    it "ignores a comment it already processed" do
      run.update!(last_pull_request_comment_id: "200")
      allow(Orchestrator::RunSessionRunner).to receive(:prompt!)

      expect(described_class.resume!(run, comment(id: 150))).to eq(:already_processed)
      expect(Orchestrator::RunSessionRunner).not_to have_received(:prompt!)
    end

    # Rails posts its own publication updates to the same PR; reacting to
    # those would have the run talking to itself forever.
    it "skips its own outbound comment while still advancing the cursor" do
      RunOutboundComment.record!(run:, github_comment_id: "300", kind: "publication_update")
      allow(Orchestrator::RunSessionRunner).to receive(:prompt!)

      expect(described_class.resume!(run, comment(id: 300))).to eq(:outbound_comment_skipped)

      expect(Orchestrator::RunSessionRunner).not_to have_received(:prompt!)
      expect(run.reload.last_pull_request_comment_id).to eq("300")
    end

    it "does nothing for a run whose PR has already merged" do
      run.update!(publication_status: "merged")
      allow(Orchestrator::RunSessionRunner).to receive(:prompt!)

      expect(described_class.resume!(run, comment(id: 400))).to eq(:merged)
      expect(Orchestrator::RunSessionRunner).not_to have_received(:prompt!)
    end
  end

  describe ".comments_after" do
    it "returns only comments newer than the recorded cursor, oldest first" do
      run.update!(last_pull_request_comment_id: "100")
      payload = JSON.generate([ comment(id: 99), comment(id: 120), comment(id: 110) ])
      allow(Open3).to receive(:capture3)
        .and_return([ payload, "", instance_double(Process::Status, success?: true, exitstatus: 0) ])

      expect(described_class.comments_after(run).map { |c| c["id"] }).to eq([ 110, 120 ])
    end

    it "raises rather than silently returning nothing when gh fails" do
      allow(Open3).to receive(:capture3)
        .and_return([ "[]", "gh: rate limited", instance_double(Process::Status, success?: false, exitstatus: 1) ])

      expect { described_class.comments_after(run) }.to raise_error(described_class::Error, /gh api comments failed/)
    end
  end
end

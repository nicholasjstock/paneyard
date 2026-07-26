class FinalizeRunPublicationJob < ApplicationJob
  queue_as :default

  def perform(id)
    run = Run.find(id)
    result = Orchestrator::RunPublication.publish!(run)
    return if result == :unmanaged
    if result == :merge_conflict
      Orchestrator::MergeConflictResolution.queue_worker!(run)
      return
    end
    run.update!(status: "completed", stopped_at: run.stopped_at || Time.current)
    summary = if result == :no_changes
      "Run completed with no source changes; no PR was created."
    else
      open_review_question!(run)
      "Pull request ready for review: #{run.pull_request_url}"
    end
    run.publish_phase!(phase: "completed", owner: "orchestrator", summary: summary)
  rescue Orchestrator::RunPublication::Error => error
    run.update!(status: "failed") if run&.persisted?
    run&.publish_phase!(phase: "failed", owner: "orchestrator", summary: "PR publication failed: #{error.message}")
  end

  private

  # A published PR has nothing open to answer unless something asked a
  # question -- but Orchestrator::PullRequestResume only resumes a run by
  # answering its one open blocking question, so a completed run needs one
  # too, to give a reviewer's "this isn't actually done" PR comment the same
  # mechanism a chaperone-raised block already has. Idempotent: a retried
  # job (or an already-published run reaching this branch again) must not
  # pile up duplicate review questions.
  def open_review_question!(run)
    return if run.open_blocking_question?

    UserQuestion.create!(
      run_id: run.run_id, asked_by: "orchestrator", scope: "pull_request_review", priority: "blocking",
      text: "This run's work is ready for review. Reply on this PR to continue the run with further " \
            "instructions, or approve/merge if it's complete."
    )
  end
end

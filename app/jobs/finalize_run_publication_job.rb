class FinalizeRunPublicationJob < ApplicationJob
  queue_as :default

  def perform(id)
    run = Run.find(id)
    result = Orchestrator::RunPublication.publish!(run)
    return if result == :unmanaged
    run.update!(status: "completed", stopped_at: run.stopped_at || Time.current)
    summary = result == :no_changes ? "Run completed with no source changes; no PR was created." : "Pull request published: #{run.pull_request_url}"
    run.publish_phase!(phase: "completed", owner: "orchestrator", summary: summary)
  rescue Orchestrator::RunPublication::Error => error
    run.update!(status: "failed") if run&.persisted?
    run&.publish_phase!(phase: "failed", owner: "orchestrator", summary: "PR publication failed: #{error.message}")
  end
end

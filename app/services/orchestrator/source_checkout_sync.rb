require "open3"

module Orchestrator
  module SourceCheckoutSync
    module_function

    def after_merge!(run)
      root = Pathname(run.source_root)
      return :skipped unless root.directory?
      return queue_worker!(run, root) unless clean?(root)

      _output, _error, status = Open3.capture3("git", "-C", root.to_s, "fetch", "origin", "main")
      return queue_worker!(run, root) unless status.success?

      _output, _error, status = Open3.capture3("git", "-C", root.to_s, "merge", "--ff-only", "origin/main")
      status.success? ? :synced : queue_worker!(run, root)
    end

    def clean?(root)
      output, _error, status = Open3.capture3("git", "-C", root.to_s, "status", "--porcelain")
      status.success? && output.blank?
    end
    private_class_method :clean?

    def queue_worker!(run, root)
      return :queued if SpawnRequest.open_only.exists?(run_id: run.run_id, requested_role: "git", scope: "source-sync.md")

      SpawnRequest.create!(
        run_id: run.run_id, asked_by: "post_merge_sync", requested_role: "git", priority: "blocking",
        scope: "source-sync.md", execution_mode: "implementation", write_scope: "git_managed", allowed_paths: [ "**/*" ],
        working_root: root.to_s, tags: %w[git source-sync],
        text: "Synchronize the assigned source checkout with origin/main. Preserve every local edit: create a named stash including untracked files, fetch origin main, rebase local main onto origin/main, resolve clear conflicts, then reapply the stash and resolve clear conflicts. If anything is ambiguous, abort the rebase or restore the stash so the checkout is never left mid-operation, then report [BLOCKED] through worker_turn. On success report [DONE] through worker_turn; do not publish a pull request."
      )
      SpawnRequestedWorkers.call(run:)
      :queued
    end
    private_class_method :queue_worker!
  end
end

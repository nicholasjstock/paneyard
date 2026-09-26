require "open3"

module Orchestrator
  # Fast-forwards a workspace's `main` checkout after one of its runs merges,
  # so the next run branches from current code.
  #
  # Best-effort by design. When main is dirty or the fast-forward is not
  # clean, this reports :dirty/:diverged and leaves the checkout untouched:
  # the operator's own uncommitted work in main is theirs, and silently
  # rebasing around it is exactly the kind of thing this tool must not do to
  # a repository it also edits.
  #
  # This used to dispatch a git-role worker to stash, rebase, and reapply.
  # That existed because the old architecture had a worker sitting there
  # anyway; spawning a whole agent session to run three git commands is not a
  # trade worth making now.
  module SourceCheckoutSync
    module_function

    def after_merge!(run)
      root = Pathname(run.source_root.to_s)
      return :skipped unless root.directory?
      return :dirty unless clean?(root)

      _output, _error, status = Open3.capture3("git", "-C", root.to_s, "fetch", "origin", "main")
      return :unreachable unless status.success?

      _output, _error, status = Open3.capture3("git", "-C", root.to_s, "merge", "--ff-only", "origin/main")
      return :synced if status.success?

      Rails.logger.info(
        "SourceCheckoutSync: #{root} could not fast-forward to origin/main; leaving it for the operator."
      )
      :diverged
    end

    def clean?(root)
      output, _error, status = Open3.capture3("git", "-C", root.to_s, "status", "--porcelain")
      status.success? && output.blank?
    end
  end
end

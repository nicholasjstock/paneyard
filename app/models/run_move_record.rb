# A run moving from one runner (machine) to another: Orchestrator::RunMove.
#
# Append-only history, one row per move, like RunCheckpoint: where it went,
# what crossed (`transferred`), and the worktree it left behind on the runner
# it left. That worktree is no longer the run's (the run's target_root is now
# on to_runner), so this row is what keeps it in view: WorktreeJanitor sweeps
# every `kept` one on its runner under the usual rule -- removed once it is
# clean and its work is in the base branch or pushed, kept indefinitely
# otherwise -- and nothing else removes it.
class RunMoveRecord < ApplicationRecord
  # Not RunMove: inside the Orchestrator module that is the move itself.
  self.table_name = "run_moves"

  SOURCE_WORKTREE_STATES = %w[none kept removed reused error].freeze

  belongs_to :run
  belongs_to :from_runner, class_name: "RegisteredRunner"
  belongs_to :to_runner, class_name: "RegisteredRunner"

  validates :source_repository_path, :target_root, presence: true
  validates :source_worktree, inclusion: { in: SOURCE_WORKTREE_STATES }

  scope :chronological, -> { order(:created_at, :id) }
  # Worktrees left behind that may still hold work (an error is retried too).
  scope :left_behind, -> { where(source_worktree: %w[kept error]).where.not(source_target_root: [ nil, "" ]) }
end

# Durable record of a comment the orchestrator posted to a run's GitHub
# conversation. This deliberately records provenance by comment id rather than
# GitHub author: when the App is unavailable, gh may post as the operator's
# personal account, whose replies must still be allowed to resume a run.
class RunOutboundComment < ApplicationRecord
  KINDS = %w[question reply publication_update].freeze

  belongs_to :run, foreign_key: :run_id, primary_key: :run_id

  validates :run_id, :github_comment_id, :kind, presence: true
  validates :github_comment_id, uniqueness: { scope: :run_id }
  validates :kind, inclusion: { in: KINDS }

  def self.record!(run:, github_comment_id:, kind:)
    create_or_find_by!(run_id: run.run_id, github_comment_id: github_comment_id.to_s) do |comment|
      comment.kind = kind
    end
  end
end

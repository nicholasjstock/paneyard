class WorkspaceMemoryEntry < ApplicationRecord
  KINDS = %w[architecture convention operational_rule known_hazard].freeze
  STATUSES = %w[confirmed superseded].freeze
  # "session" replaced the planner/project_init recorders: every entry now
  # comes from a run's own session, or from the operator by hand.
  RECORDERS = %w[session operator].freeze

  belongs_to :workspace
  belongs_to :supersedes, class_name: "WorkspaceMemoryEntry", optional: true

  validates :entry_key, :kind, :status, :content, :evidence_ref, :recorded_by, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :recorded_by, inclusion: { in: RECORDERS }

  scope :current, -> { where.not(status: "superseded") }

  def as_json(*)
    {
      key: entry_key,
      kind: kind,
      status: status,
      content: content,
      evidenceRef: evidence_ref,
      recordedBy: recorded_by,
      supersedesId: supersedes_id,
      updatedAt: updated_at.iso8601(3)
    }
  end
end

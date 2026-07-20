class RunContextEntry < ApplicationRecord
  KINDS = %w[fact constraint rejected_approach operator_decision].freeze
  STATUSES = %w[pending confirmed verified waived rejected superseded].freeze

  belongs_to :run, foreign_key: :run_id, primary_key: :run_id, optional: true, inverse_of: :run_context_entries

  validates :run_id, :entry_key, :kind, :status, :content, :created_by, presence: true
  validates :entry_key, uniqueness: { scope: :run_id }
  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :evidence_ref, presence: true, if: :evidence_required?

  after_commit :publish_change

  def as_json(*)
    {
      key: entry_key,
      kind: kind,
      status: status,
      content: content,
      evidenceRef: evidence_ref,
      createdBy: created_by,
      updatedAt: updated_at.iso8601(3)
    }
  end

  private

  def evidence_required?
    kind == "fact"
  end

  def publish_change
    BusEvent.publish("run_context.updated", run_id: run_id, payload: as_json)
  end
end

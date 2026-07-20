class AcceptanceCriterion < ApplicationRecord
  STATUSES = %w[pending in_progress verified waived blocked].freeze
  KEY_FORMAT = /\A[a-z0-9][a-z0-9-]{0,63}\z/

  belongs_to :run, foreign_key: :run_id, primary_key: :run_id, inverse_of: :acceptance_criteria
  belongs_to :parent, class_name: "AcceptanceCriterion", optional: true, inverse_of: :children
  has_many :children, class_name: "AcceptanceCriterion", foreign_key: :parent_id, dependent: :destroy, inverse_of: :parent
  has_many :fulfillment_steps, class_name: "AcceptanceCriterionStep", dependent: :destroy

  validates :key, presence: true, uniqueness: { scope: :run_id }, format: { with: KEY_FORMAT }
  validates :content, :status, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :evidence_ref, presence: true, if: -> { status == "verified" }

  scope :roots, -> { where(parent_id: nil) }

  # A criterion with children is resolved when every child is -- its own
  # `status` is not read once it has children, so a parent never needs a
  # separate verification pass; a leaf resolves through the ordinary
  # verified/waived transition. Recurses naturally to any depth.
  def resolved?
    children.any? ? children.all?(&:resolved?) : status.in?(%w[verified waived])
  end
end

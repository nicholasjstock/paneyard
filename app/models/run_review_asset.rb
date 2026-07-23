class RunReviewAsset < ApplicationRecord
  belongs_to :run, foreign_key: :run_id, primary_key: :run_id, inverse_of: :review_assets

  validates :workspace_path, :label, presence: true
end

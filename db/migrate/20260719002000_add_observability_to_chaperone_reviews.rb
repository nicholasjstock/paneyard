class AddObservabilityToChaperoneReviews < ActiveRecord::Migration[8.1]
  def change
    add_column :chaperone_reviews, :trigger_reason, :text
    add_column :chaperone_reviews, :model, :string
    add_column :chaperone_reviews, :stdout, :text
    add_column :chaperone_reviews, :stderr, :text
    add_column :chaperone_reviews, :tool_calls, :json, null: false, default: []
    add_column :chaperone_reviews, :started_at, :datetime
  end
end

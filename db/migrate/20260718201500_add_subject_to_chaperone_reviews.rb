class AddSubjectToChaperoneReviews < ActiveRecord::Migration[8.1]
  def change
    add_column :chaperone_reviews, :subject_type, :string, null: false, default: "diagnosis"
    add_column :chaperone_reviews, :subject_id, :string
    add_index :chaperone_reviews, [ :subject_type, :subject_id, :status ], name: "index_chaperone_reviews_on_subject_and_status"
  end
end

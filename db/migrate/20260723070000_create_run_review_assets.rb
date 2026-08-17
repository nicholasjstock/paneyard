class CreateRunReviewAssets < ActiveRecord::Migration[8.1]
  def change
    create_table :run_review_assets do |t|
      t.string :run_id, null: false
      t.string :workspace_path, null: false
      t.string :label, null: false
      t.string :github_url
      t.timestamps
    end

    add_index :run_review_assets, [ :run_id, :workspace_path ], unique: true
  end
end

class CreateStepAttempts < ActiveRecord::Migration[8.1]
  def change
    add_column :spawn_requests, :lineage_key, :string
    add_column :spawn_requests, :model_tier, :string, null: false, default: "small"

    create_table :step_attempts do |t|
      t.string :attempt_id, null: false
      t.string :run_id, null: false
      t.string :spawn_request_id, null: false
      t.string :worker_id
      t.string :lineage_key, null: false
      t.string :mode, null: false
      t.string :outcome, null: false
      t.text :result, null: false
      t.string :evidence_outcome
      t.json :evidence_citations, null: false, default: []
      t.string :chaperone_status
      t.string :chaperone_action
      t.text :chaperone_summary
      t.timestamps
    end

    add_index :step_attempts, :attempt_id, unique: true
    add_index :step_attempts, [ :run_id, :lineage_key ]

    create_table :chaperone_reviews do |t|
      t.string :review_id, null: false
      t.string :run_id, null: false
      t.string :lineage_key, null: false
      t.string :status, null: false, default: "queued"
      t.string :token_digest, null: false
      t.json :step_attempt_ids, null: false, default: []
      t.string :action
      t.text :summary
      t.datetime :expires_at, null: false
      t.datetime :completed_at
      t.timestamps
    end

    add_index :chaperone_reviews, :review_id, unique: true
    add_index :chaperone_reviews, :token_digest, unique: true
    add_index :chaperone_reviews, [ :run_id, :status ]
  end
end

class CreateRunCheckpoints < ActiveRecord::Migration[8.1]
  def change
    create_table :run_checkpoints do |t|
      t.references :run, null: false, foreign_key: true
      t.references :run_session, null: false, foreign_key: true
      t.string :outcome, null: false
      t.text :summary
      t.datetime :created_at, null: false
    end
  end
end

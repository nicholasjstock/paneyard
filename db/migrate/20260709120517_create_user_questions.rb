class CreateUserQuestions < ActiveRecord::Migration[8.1]
  def change
    create_table :user_questions do |t|
      t.string :question_id, null: false
      t.string :run_id, null: false
      t.string :asked_by, null: false
      t.datetime :asked_at, null: false
      t.string :scope, null: false
      t.text :text, null: false
      t.text :context
      t.string :priority, null: false, default: "advisory"
      t.string :status, null: false, default: "open"
      t.json :tags, null: false, default: []
      t.string :answered_by
      t.datetime :answered_at
      t.text :answer_text

      t.timestamps
    end
    add_index :user_questions, :question_id, unique: true
    add_index :user_questions, [ :run_id, :status ]
  end
end

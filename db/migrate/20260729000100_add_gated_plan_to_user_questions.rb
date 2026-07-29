class AddGatedPlanToUserQuestions < ActiveRecord::Migration[8.1]
  def change
    add_column :user_questions, :gated_next_step, :json, default: {}, null: false
    add_column :user_questions, :gated_following_steps, :json, default: [], null: false
  end
end

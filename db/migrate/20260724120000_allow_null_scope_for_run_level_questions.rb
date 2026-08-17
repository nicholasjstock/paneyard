class AllowNullScopeForRunLevelQuestions < ActiveRecord::Migration[7.1]
  def change
    change_column_null :user_questions, :scope, true
  end
end

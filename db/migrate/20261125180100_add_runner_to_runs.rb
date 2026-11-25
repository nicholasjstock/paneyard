class AddRunnerToRuns < ActiveRecord::Migration[8.1]
  # Every run so far happened on this machine, so every existing run belongs
  # to the local runner (inserted by CreateRunners).
  def up
    add_reference :runs, :runner, foreign_key: true
    execute "UPDATE runs SET runner_id = (SELECT id FROM runners WHERE kind = 'local')"
    change_column_null :runs, :runner_id, false
  end

  def down
    remove_reference :runs, :runner, foreign_key: true
  end
end

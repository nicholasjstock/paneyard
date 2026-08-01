class CreateWorkspaceEnvVars < ActiveRecord::Migration[8.1]
  def change
    create_table :workspace_env_vars do |t|
      t.references :workspace, null: false, foreign_key: true
      t.string :name, null: false
      t.text :value, null: false
      t.string :evidence_ref, null: false
      t.string :recorded_by, null: false

      t.timestamps
    end

    add_index :workspace_env_vars, [ :workspace_id, :name ], unique: true
  end
end

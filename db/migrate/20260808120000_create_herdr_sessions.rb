class CreateHerdrSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :herdr_sessions do |t|
      t.references :workspace, null: false, foreign_key: true, index: { unique: true }
      t.string :status, null: false, default: "provisioning"
      t.string :herdr_workspace_id
      t.string :herdr_tab_id
      t.string :herdr_pane_id
      t.string :label
      t.timestamps
    end
  end
end

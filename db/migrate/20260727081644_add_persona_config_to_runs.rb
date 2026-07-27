class AddPersonaConfigToRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :runs, :persona_config, :json, default: {}, null: false
  end
end

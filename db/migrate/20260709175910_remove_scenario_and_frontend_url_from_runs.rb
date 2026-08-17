class RemoveScenarioAndFrontendUrlFromRuns < ActiveRecord::Migration[8.1]
  def change
    remove_column :runs, :scenario, :string
    remove_column :runs, :frontend_url, :string
  end
end

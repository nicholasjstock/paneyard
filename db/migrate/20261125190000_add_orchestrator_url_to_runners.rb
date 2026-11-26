class AddOrchestratorUrlToRunners < ActiveRecord::Migration[8.1]
  def change
    # Where a remote runner's sessions reach this orchestrator's /mcp: its
    # tailnet URL as that machine sees it (the plugin's PANEYARD_REMOTE_URL),
    # given when the runner registers. Nil for the local runner, whose
    # sessions use PANEYARD_RAILS_URL (RunSessionRunner.mcp_url).
    add_column :runners, :orchestrator_url, :string
  end
end

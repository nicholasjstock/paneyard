class AddSessionEvidenceToRunSessions < ActiveRecord::Migration[8.1]
  def change
    # The agent pane's last screen, read just before Paneyard killed the CLI
    # or closed the pane (Orchestrator::RunSessionRunner#keep_last_screen!).
    add_column :run_sessions, :last_screen, :text
    # The runner's saved copies of the CLI's own conversation transcripts,
    # taken when the session ended (Orchestrator::Runner::Transcripts).
    add_column :run_sessions, :transcript_paths, :json, default: [], null: false
    # A record of each start of the CLI that never picked its prompt up and
    # was restarted (Orchestrator::Runner::SessionLauncher#launch).
    add_column :run_sessions, :lost_prompts, :json, default: [], null: false
  end
end

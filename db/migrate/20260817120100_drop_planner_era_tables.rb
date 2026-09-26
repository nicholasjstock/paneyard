# Drops every table that existed only to serve the planner loop and its
# compensating machinery. All of it is gone from the code in the same change;
# leaving the tables behind would only make db/schema.rb lie about what this
# application is.
#
# Irreversible on purpose: these tables' contents are the decision history of
# an orchestration model that no longer exists, and there is nothing in the
# new one that could read them.
class DropPlannerEraTables < ActiveRecord::Migration[8.1]
  def up
    # The planner loop itself.
    drop_table :planner_decision_attempts, if_exists: true
    drop_table :planner_decisions, if_exists: true
    drop_table :orchestrator_ticks, if_exists: true
    drop_table :spawn_requests, if_exists: true
    drop_table :step_attempts, if_exists: true

    # Adjudication and verification, which existed only to recover from
    # repeated planner/worker step failures.
    drop_table :chaperone_reviews, if_exists: true
    drop_table :reply_received_reviews, if_exists: true
    drop_table :acceptance_criterion_steps, if_exists: true
    drop_table :acceptance_criteria, if_exists: true

    # The per-step worker registry, replaced by run_sessions.
    drop_table :workers, if_exists: true

    # The GitHub-mediated question protocol, replaced by typing into the live
    # session's pane. notifications holds a foreign key into user_questions,
    # so it has to go first.
    drop_table :notifications, if_exists: true
    drop_table :user_questions, if_exists: true

    # Planner-curated run knowledge; a continuous session holds this in its
    # own context.
    drop_table :run_context_entries, if_exists: true

    # Curator-selected review assets, which went with the finalization chain.
    drop_table :run_review_assets, if_exists: true

    # Ad-hoc surfaces a session no longer needs: it has its own real terminal.
    drop_table :run_commands, if_exists: true
    drop_table :terminal_sessions, if_exists: true

    # Superseded by run_sessions (per run, not per workspace).
    drop_table :herdr_sessions, if_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end

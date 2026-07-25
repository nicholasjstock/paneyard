# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_25_090000) do
  create_table "acceptance_criteria", force: :cascade do |t|
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.string "evidence_ref"
    t.string "key", null: false
    t.integer "parent_id"
    t.string "run_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["parent_id"], name: "index_acceptance_criteria_on_parent_id"
    t.index ["run_id", "key"], name: "index_acceptance_criteria_on_run_id_and_key", unique: true
  end

  create_table "acceptance_criterion_steps", force: :cascade do |t|
    t.integer "acceptance_criterion_id", null: false
    t.datetime "created_at", null: false
    t.string "lineage_key", null: false
    t.string "run_id", null: false
    t.datetime "updated_at", null: false
    t.index ["acceptance_criterion_id", "lineage_key"], name: "idx_on_acceptance_criterion_id_lineage_key_539667c7eb"
    t.index ["acceptance_criterion_id"], name: "index_acceptance_criterion_steps_on_acceptance_criterion_id"
  end

  create_table "bus_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "event_id", null: false
    t.string "event_type", null: false
    t.json "payload", default: {}, null: false
    t.string "run_id"
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_bus_events_on_event_id", unique: true
    t.index ["run_id"], name: "index_bus_events_on_run_id"
  end

  create_table "chaperone_reviews", force: :cascade do |t|
    t.string "action"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "lineage_key", null: false
    t.string "model"
    t.string "review_id", null: false
    t.string "run_id", null: false
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.text "stderr"
    t.text "stdout"
    t.json "step_attempt_ids", default: [], null: false
    t.string "subject_id"
    t.string "subject_type", default: "diagnosis", null: false
    t.text "summary"
    t.string "token_digest", null: false
    t.json "tool_calls", default: [], null: false
    t.text "trigger_reason"
    t.datetime "updated_at", null: false
    t.index ["review_id"], name: "index_chaperone_reviews_on_review_id", unique: true
    t.index ["run_id", "status"], name: "index_chaperone_reviews_on_run_id_and_status"
    t.index ["subject_type", "subject_id", "status"], name: "index_chaperone_reviews_on_subject_and_status"
    t.index ["token_digest"], name: "index_chaperone_reviews_on_token_digest", unique: true
  end

  create_table "guarded_command_executions", force: :cascade do |t|
    t.json "args", default: [], null: false
    t.string "command", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.string "cwd", null: false
    t.string "execution_id", null: false
    t.integer "exit_code"
    t.string "exit_status_path", null: false
    t.string "log_path", null: false
    t.string "operation", null: false
    t.integer "pid", default: 0, null: false
    t.string "run_id", null: false
    t.datetime "started_at"
    t.string "status", default: "launching", null: false
    t.datetime "updated_at", null: false
    t.string "worker_id", null: false
    t.index ["execution_id"], name: "index_guarded_command_executions_on_execution_id", unique: true
    t.index ["run_id", "operation"], name: "index_guarded_command_executions_on_run_id_and_operation"
    t.index ["worker_id", "status"], name: "index_guarded_command_executions_on_worker_id_and_status"
  end

  create_table "memory_candidates", force: :cascade do |t|
    t.text "approach", null: false
    t.string "candidate_id", null: false
    t.datetime "created_at", null: false
    t.string "lineage_key", null: false
    t.text "next_approach"
    t.text "reason", null: false
    t.string "role"
    t.string "run_id", null: false
    t.string "status", default: "proposed", null: false
    t.datetime "updated_at", null: false
    t.string "worker_id"
    t.index ["candidate_id"], name: "index_memory_candidates_on_candidate_id", unique: true
    t.index ["run_id", "lineage_key"], name: "index_memory_candidates_on_run_id_and_lineage_key"
    t.index ["status"], name: "index_memory_candidates_on_status"
  end

  create_table "orchestrator_ticks", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "following_steps", default: [], null: false
    t.text "last_plan_summary"
    t.text "last_stall_finding"
    t.json "pending_spawn_keys", default: [], null: false
    t.string "phase", null: false
    t.string "run_id", null: false
    t.integer "tick_count", null: false
    t.datetime "updated_at", null: false
    t.index ["run_id", "tick_count"], name: "index_orchestrator_ticks_on_run_id_and_tick_count", unique: true
  end

  create_table "planner_decision_attempts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "disposition", default: "proposed", null: false
    t.string "model"
    t.string "model_tier", null: false
    t.string "outcome", null: false
    t.integer "planner_decision_id", null: false
    t.json "proposal", default: {}, null: false
    t.text "rejection_reason"
    t.integer "sequence", null: false
    t.datetime "updated_at", null: false
    t.json "usage", default: {}, null: false
    t.index ["planner_decision_id", "sequence"], name: "idx_on_planner_decision_id_sequence_e323d6f32e", unique: true
    t.index ["planner_decision_id"], name: "index_planner_decision_attempts_on_planner_decision_id"
  end

  create_table "planner_decisions", force: :cascade do |t|
    t.integer "cache_read_input_tokens"
    t.text "cli_output"
    t.datetime "completed_at"
    t.integer "context_bytes", default: 0, null: false
    t.json "context_requests", default: [], null: false
    t.datetime "created_at", null: false
    t.json "decision"
    t.string "decision_id", null: false
    t.text "error"
    t.integer "input_tokens"
    t.string "model"
    t.json "model_attempts", default: [], null: false
    t.integer "model_calls", default: 0, null: false
    t.integer "output_tokens"
    t.string "run_id", null: false
    t.string "spawn_request_id", null: false
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.decimal "total_cost_usd", precision: 12, scale: 6
    t.datetime "updated_at", null: false
    t.index ["decision_id"], name: "index_planner_decisions_on_decision_id", unique: true
    t.index ["run_id", "status"], name: "index_planner_decisions_on_run_id_and_status"
    t.index ["spawn_request_id"], name: "index_planner_decisions_on_spawn_request_id", unique: true
  end

  create_table "run_commands", force: :cascade do |t|
    t.json "arguments", default: [], null: false
    t.string "command_id", null: false
    t.datetime "created_at", null: false
    t.json "environment", default: {}, null: false
    t.string "executable", null: false
    t.integer "exit_code"
    t.string "exit_status_path"
    t.text "failure_message"
    t.datetime "finished_at"
    t.datetime "last_checked_at"
    t.string "log_path"
    t.integer "pid"
    t.integer "process_group_id"
    t.text "purpose"
    t.string "requested_by_worker_id"
    t.string "run_id", null: false
    t.integer "signal"
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.string "working_directory", null: false
    t.index ["command_id"], name: "index_run_commands_on_command_id", unique: true
    t.index ["run_id", "status"], name: "index_run_commands_on_run_id_and_status"
  end

  create_table "run_context_entries", force: :cascade do |t|
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.string "created_by", null: false
    t.string "entry_key", null: false
    t.string "evidence_ref"
    t.string "kind", null: false
    t.string "run_id", null: false
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.index ["run_id", "entry_key"], name: "index_run_context_entries_on_run_id_and_entry_key", unique: true
    t.index ["run_id", "kind"], name: "index_run_context_entries_on_run_id_and_kind"
  end

  create_table "run_review_assets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "github_url"
    t.string "label", null: false
    t.string "run_id", null: false
    t.datetime "updated_at", null: false
    t.string "workspace_path", null: false
    t.index ["run_id", "workspace_path"], name: "index_run_review_assets_on_run_id_and_workspace_path", unique: true
  end

  create_table "runs", force: :cascade do |t|
    t.string "active_branch_key"
    t.string "base_sha"
    t.string "branch_name"
    t.datetime "capacity_available_at"
    t.string "conversation_pr_status"
    t.datetime "created_at", null: false
    t.string "last_pull_request_comment_id"
    t.string "launched_by"
    t.string "launcher_variant", default: "claude", null: false
    t.string "log_path"
    t.string "phase"
    t.string "phase_owner"
    t.text "phase_summary"
    t.datetime "phase_updated_at"
    t.datetime "publication_completed_at"
    t.text "publication_error"
    t.datetime "publication_started_at"
    t.string "publication_status"
    t.string "pull_request_url"
    t.string "run_id", null: false
    t.string "source_root"
    t.datetime "started_at"
    t.string "status", default: "launching", null: false
    t.datetime "stopped_at"
    t.integer "supervisor_pid"
    t.string "target_root", null: false
    t.text "task", null: false
    t.datetime "updated_at", null: false
    t.integer "workspace_id", null: false
    t.string "worktree_name"
    t.index ["active_branch_key"], name: "index_runs_on_active_branch_key"
    t.index ["capacity_available_at"], name: "index_runs_on_capacity_available_at"
    t.index ["conversation_pr_status"], name: "index_runs_on_conversation_pr_status"
    t.index ["publication_status"], name: "index_runs_on_publication_status"
    t.index ["run_id"], name: "index_runs_on_run_id", unique: true
    t.index ["status"], name: "index_runs_on_status"
    t.index ["workspace_id"], name: "index_runs_on_workspace_id"
    t.index ["worktree_name"], name: "index_runs_on_worktree_name"
  end

  create_table "spawn_requests", force: :cascade do |t|
    t.json "allowed_paths", default: [], null: false
    t.datetime "asked_at", null: false
    t.string "asked_by", null: false
    t.text "context"
    t.datetime "created_at", null: false
    t.text "dismissal_note"
    t.datetime "dismissed_at"
    t.string "dismissed_by"
    t.json "evidence_refs", default: [], null: false
    t.string "execution_mode"
    t.datetime "fulfilled_at"
    t.string "fulfilled_by"
    t.string "fulfilled_worker_id"
    t.text "fulfillment_note"
    t.string "lineage_key"
    t.string "model_tier", default: "small", null: false
    t.string "priority", default: "advisory", null: false
    t.string "request_id", null: false
    t.string "requested_role", null: false
    t.string "run_id", null: false
    t.string "scope", null: false
    t.string "status", default: "open", null: false
    t.json "tags", default: [], null: false
    t.text "text", null: false
    t.datetime "updated_at", null: false
    t.string "write_scope"
    t.index ["request_id"], name: "index_spawn_requests_on_request_id", unique: true
    t.index ["run_id", "status"], name: "index_spawn_requests_on_run_id_and_status"
  end

  create_table "step_attempts", force: :cascade do |t|
    t.string "attempt_id", null: false
    t.string "chaperone_action"
    t.string "chaperone_status"
    t.text "chaperone_summary"
    t.datetime "created_at", null: false
    t.json "evidence_citations", default: [], null: false
    t.string "evidence_outcome"
    t.string "lineage_key", null: false
    t.string "mode", null: false
    t.string "outcome", null: false
    t.text "result", null: false
    t.string "run_id", null: false
    t.string "spawn_request_id", null: false
    t.datetime "updated_at", null: false
    t.string "worker_id"
    t.index ["attempt_id"], name: "index_step_attempts_on_attempt_id", unique: true
    t.index ["run_id", "lineage_key"], name: "index_step_attempts_on_run_id_and_lineage_key"
  end

  create_table "terminal_sessions", force: :cascade do |t|
    t.string "cli_session_id"
    t.integer "cols"
    t.datetime "created_at", null: false
    t.integer "exit_code"
    t.string "exit_status_path"
    t.datetime "last_attached_at"
    t.string "launcher_variant", default: "claude", null: false
    t.string "log_path"
    t.integer "pid"
    t.integer "process_group_id"
    t.integer "rows"
    t.integer "signal"
    t.datetime "started_at"
    t.string "status", default: "starting", null: false
    t.datetime "stopped_at"
    t.datetime "updated_at", null: false
    t.integer "workspace_id", null: false
    t.index ["workspace_id"], name: "index_terminal_sessions_on_workspace_id", unique: true
  end

  create_table "user_questions", force: :cascade do |t|
    t.text "answer_text"
    t.datetime "answered_at"
    t.string "answered_by"
    t.datetime "asked_at", null: false
    t.string "asked_by", null: false
    t.text "context"
    t.datetime "created_at", null: false
    t.string "github_comment_id"
    t.string "github_comment_url"
    t.text "github_publication_error"
    t.datetime "github_published_at"
    t.string "priority", default: "advisory", null: false
    t.string "question_id", null: false
    t.string "run_id", null: false
    t.string "scope", null: false
    t.string "status", default: "open", null: false
    t.json "tags", default: [], null: false
    t.text "text", null: false
    t.datetime "updated_at", null: false
    t.index ["github_comment_id"], name: "index_user_questions_on_github_comment_id", unique: true
    t.index ["question_id"], name: "index_user_questions_on_question_id", unique: true
    t.index ["run_id", "status"], name: "index_user_questions_on_run_id_and_status"
  end

  create_table "workers", force: :cascade do |t|
    t.integer "agent_turn_count"
    t.json "allowed_paths", default: [], null: false
    t.json "args", default: [], null: false
    t.bigint "cache_creation_input_tokens"
    t.bigint "cache_read_input_tokens"
    t.string "capability_token_digest"
    t.string "cli_session_id"
    t.string "command", null: false
    t.datetime "created_at", null: false
    t.string "env_path", null: false
    t.string "execution_mode"
    t.integer "exit_code"
    t.string "exit_status_path"
    t.datetime "handoff_completed_at"
    t.bigint "input_tokens"
    t.string "last_message_path", null: false
    t.string "lineage_key"
    t.string "log_path", null: false
    t.datetime "log_updated_at"
    t.string "mcp_config_path"
    t.string "model"
    t.string "nickname", null: false
    t.bigint "output_tokens"
    t.integer "pid", null: false
    t.string "prompt_path", null: false
    t.text "reason", null: false
    t.string "role", null: false
    t.string "run_id", null: false
    t.string "scope", null: false
    t.datetime "started_at", null: false
    t.string "status", default: "running", null: false
    t.text "stop_reason"
    t.datetime "stopped_at"
    t.decimal "total_cost_usd", precision: 12, scale: 6
    t.datetime "updated_at", null: false
    t.string "worker_id", null: false
    t.string "write_scope"
    t.index ["capability_token_digest"], name: "index_workers_on_capability_token_digest", unique: true
    t.index ["run_id", "lineage_key", "role"], name: "index_workers_on_run_id_and_lineage_key_and_role"
    t.index ["run_id", "status"], name: "index_workers_on_run_id_and_status"
    t.index ["worker_id"], name: "index_workers_on_worker_id", unique: true
  end

  create_table "workspace_memory_entries", force: :cascade do |t|
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.string "entry_key", null: false
    t.string "evidence_ref", null: false
    t.string "kind", null: false
    t.string "recorded_by", null: false
    t.string "status", null: false
    t.integer "supersedes_id"
    t.datetime "updated_at", null: false
    t.integer "workspace_id", null: false
    t.index ["supersedes_id"], name: "index_workspace_memory_entries_on_supersedes_id"
    t.index ["workspace_id", "entry_key"], name: "index_workspace_memory_entries_on_workspace_id_and_entry_key"
    t.index ["workspace_id", "status"], name: "index_workspace_memory_entries_on_workspace_id_and_status"
    t.index ["workspace_id"], name: "index_workspace_memory_entries_on_workspace_id"
  end

  create_table "workspaces", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.json "protected_path_patterns", default: [], null: false
    t.string "root_path", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_workspaces_on_name", unique: true
    t.index ["root_path"], name: "index_workspaces_on_root_path", unique: true
  end

  add_foreign_key "acceptance_criteria", "acceptance_criteria", column: "parent_id"
  add_foreign_key "acceptance_criterion_steps", "acceptance_criteria"
  add_foreign_key "planner_decision_attempts", "planner_decisions"
  add_foreign_key "runs", "workspaces"
  add_foreign_key "terminal_sessions", "workspaces"
  add_foreign_key "workspace_memory_entries", "workspace_memory_entries", column: "supersedes_id"
  add_foreign_key "workspace_memory_entries", "workspaces"
end

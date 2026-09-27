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

ActiveRecord::Schema[8.1].define(version: 2026_09_27_090000) do
  create_table "run_checkpoints", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "outcome", null: false
    t.integer "run_id", null: false
    t.integer "run_session_id", null: false
    t.text "summary"
    t.index ["run_id"], name: "index_run_checkpoints_on_run_id"
    t.index ["run_session_id"], name: "index_run_checkpoints_on_run_session_id"
  end

  create_table "run_sessions", force: :cascade do |t|
    t.string "agent_status"
    t.string "capability_token_digest"
    t.string "cli_session_id"
    t.datetime "created_at", null: false
    t.string "driver", null: false
    t.datetime "ended_at"
    t.string "herdr_pane_id"
    t.string "herdr_tab_id"
    t.string "herdr_workspace_id"
    t.datetime "last_seen_at"
    t.string "mcp_config_path"
    t.string "model"
    t.string "outcome"
    t.integer "pid"
    t.string "prompt_path"
    t.text "result"
    t.integer "run_id", null: false
    t.datetime "started_at"
    t.string "status", default: "starting", null: false
    t.datetime "updated_at", null: false
    t.index ["capability_token_digest"], name: "index_run_sessions_on_capability_token_digest", unique: true
    t.index ["run_id"], name: "index_run_sessions_on_one_live_session_per_run", unique: true, where: "ended_at IS NULL"
    t.index ["run_id"], name: "index_run_sessions_on_run_id"
    t.index ["status"], name: "index_run_sessions_on_status"
  end

  create_table "runs", force: :cascade do |t|
    t.string "base_sha"
    t.string "branch_name"
    t.datetime "created_at", null: false
    t.json "launch_artifacts", default: [], null: false
    t.text "launch_error"
    t.string "launched_by"
    t.string "launcher_variant", default: "claude", null: false
    t.string "model"
    t.string "run_id", null: false
    t.string "source_root"
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.datetime "stopped_at"
    t.string "target_root", null: false
    t.text "task", null: false
    t.datetime "updated_at", null: false
    t.integer "workspace_id", null: false
    t.string "worktree_name"
    t.index ["run_id"], name: "index_runs_on_run_id", unique: true
    t.index ["status"], name: "index_runs_on_status"
    t.index ["workspace_id"], name: "index_runs_on_workspace_id"
    t.index ["worktree_name"], name: "index_runs_on_worktree_name"
  end

  create_table "telegram_update_cursors", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "last_update_id", default: -1, null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_telegram_update_cursors_on_name", unique: true
  end

  create_table "workspace_env_vars", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "evidence_ref", null: false
    t.string "name", null: false
    t.string "recorded_by", null: false
    t.datetime "updated_at", null: false
    t.text "value", null: false
    t.integer "workspace_id", null: false
    t.index ["workspace_id", "name"], name: "index_workspace_env_vars_on_workspace_id_and_name", unique: true
    t.index ["workspace_id"], name: "index_workspace_env_vars_on_workspace_id"
  end

  create_table "workspaces", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "layout"
    t.string "name", null: false
    t.string "root_path", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_workspaces_on_name", unique: true
    t.index ["root_path"], name: "index_workspaces_on_root_path", unique: true
  end

  add_foreign_key "run_checkpoints", "run_sessions"
  add_foreign_key "run_checkpoints", "runs"
  add_foreign_key "run_sessions", "runs"
  add_foreign_key "runs", "workspaces"
  add_foreign_key "workspace_env_vars", "workspaces"
end

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

ActiveRecord::Schema[8.1].define(version: 2026_07_09_155601) do
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

  create_table "runs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "frontend_url"
    t.string "launched_by"
    t.string "launcher_variant", default: "claude", null: false
    t.string "log_path"
    t.string "phase"
    t.string "phase_owner"
    t.text "phase_summary"
    t.datetime "phase_updated_at"
    t.string "run_id", null: false
    t.string "scenario"
    t.datetime "started_at"
    t.string "status", default: "launching", null: false
    t.datetime "stopped_at"
    t.integer "supervisor_pid"
    t.string "target_root", null: false
    t.text "task", null: false
    t.datetime "updated_at", null: false
    t.integer "workspace_id"
    t.index ["run_id"], name: "index_runs_on_run_id", unique: true
    t.index ["status"], name: "index_runs_on_status"
    t.index ["workspace_id"], name: "index_runs_on_workspace_id"
  end

  create_table "spawn_requests", force: :cascade do |t|
    t.datetime "asked_at", null: false
    t.string "asked_by", null: false
    t.text "context"
    t.datetime "created_at", null: false
    t.text "dismissal_note"
    t.datetime "dismissed_at"
    t.string "dismissed_by"
    t.datetime "fulfilled_at"
    t.string "fulfilled_by"
    t.string "fulfilled_worker_id"
    t.text "fulfillment_note"
    t.string "priority", default: "advisory", null: false
    t.string "request_id", null: false
    t.string "requested_role", null: false
    t.string "run_id", null: false
    t.string "scope", null: false
    t.string "status", default: "open", null: false
    t.json "tags", default: [], null: false
    t.text "text", null: false
    t.datetime "updated_at", null: false
    t.index ["request_id"], name: "index_spawn_requests_on_request_id", unique: true
    t.index ["run_id", "status"], name: "index_spawn_requests_on_run_id_and_status"
  end

  create_table "user_questions", force: :cascade do |t|
    t.text "answer_text"
    t.datetime "answered_at"
    t.string "answered_by"
    t.datetime "asked_at", null: false
    t.string "asked_by", null: false
    t.text "context"
    t.datetime "created_at", null: false
    t.string "priority", default: "advisory", null: false
    t.string "question_id", null: false
    t.string "run_id", null: false
    t.string "scope", null: false
    t.string "status", default: "open", null: false
    t.json "tags", default: [], null: false
    t.text "text", null: false
    t.datetime "updated_at", null: false
    t.index ["question_id"], name: "index_user_questions_on_question_id", unique: true
    t.index ["run_id", "status"], name: "index_user_questions_on_run_id_and_status"
  end

  create_table "workers", force: :cascade do |t|
    t.json "args", default: [], null: false
    t.string "command", null: false
    t.datetime "created_at", null: false
    t.string "env_path", null: false
    t.string "last_message_path", null: false
    t.string "log_path", null: false
    t.string "nickname", null: false
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
    t.datetime "updated_at", null: false
    t.string "worker_id", null: false
    t.index ["run_id", "status"], name: "index_workers_on_run_id_and_status"
    t.index ["worker_id"], name: "index_workers_on_worker_id", unique: true
  end

  create_table "workspaces", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "root_path", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_workspaces_on_name", unique: true
    t.index ["root_path"], name: "index_workspaces_on_root_path", unique: true
  end

  add_foreign_key "runs", "workspaces"
end

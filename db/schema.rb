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

ActiveRecord::Schema[8.1].define(version: 2026_08_31_010000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "control_projects", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "last_error"
    t.string "name", null: false
    t.bigint "owner_id", null: false
    t.string "status", default: "pending", null: false
    t.string "template_name"
    t.datetime "updated_at", null: false
    t.string "uuid", null: false
    t.string "workspace_image_tag"
    t.index ["owner_id"], name: "index_control_projects_on_owner_id"
    t.index ["status"], name: "index_control_projects_on_status"
    t.index ["uuid"], name: "index_control_projects_on_uuid", unique: true
  end

  create_table "project_memberships", force: :cascade do |t|
    t.bigint "control_project_id", null: false
    t.datetime "created_at", null: false
    t.string "role", default: "member", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["control_project_id"], name: "index_project_memberships_on_control_project_id"
    t.index ["user_id", "control_project_id"], name: "index_memberships_on_user_and_project", unique: true
    t.index ["user_id"], name: "index_project_memberships_on_user_id"
  end

  create_table "settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.string "value", null: false
    t.index ["key"], name: "index_settings_on_key", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.datetime "updated_at", null: false
    t.string "uuid", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["uuid"], name: "index_users_on_uuid", unique: true
  end

  create_table "webauthn_challenges", force: :cascade do |t|
    t.string "challenge", null: false
    t.boolean "consumed", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.datetime "updated_at", null: false
    t.index ["challenge"], name: "index_webauthn_challenges_on_challenge", unique: true
    t.index ["expires_at"], name: "index_webauthn_challenges_on_expires_at"
  end

  create_table "webauthn_credentials", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "external_id", null: false
    t.string "nickname", null: false
    t.text "public_key", null: false
    t.bigint "sign_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["external_id"], name: "index_webauthn_credentials_on_external_id", unique: true
    t.index ["user_id", "nickname"], name: "index_webauthn_credentials_on_user_id_and_nickname", unique: true
    t.index ["user_id"], name: "index_webauthn_credentials_on_user_id"
  end

  create_table "workspace_templates", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "is_default", default: false, null: false
    t.string "name", null: false
    t.string "storage_size", default: "1Gi", null: false
    t.datetime "updated_at", null: false
    t.string "workspace_cpu_limit", default: "1", null: false
    t.string "workspace_cpu_request", default: "200m", null: false
    t.string "workspace_memory_limit", default: "1Gi", null: false
    t.string "workspace_memory_request", default: "512Mi", null: false
    t.index ["name"], name: "index_workspace_templates_on_name", unique: true
  end

  add_foreign_key "control_projects", "users", column: "owner_id"
  add_foreign_key "project_memberships", "control_projects"
  add_foreign_key "project_memberships", "users"
  add_foreign_key "webauthn_credentials", "users"
end

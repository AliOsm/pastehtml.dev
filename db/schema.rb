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

ActiveRecord::Schema[8.1].define(version: 2026_07_10_091356) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "api_keys", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "folder_id"
    t.string "key_digest", null: false
    t.string "key_prefix", null: false
    t.datetime "last_used_at"
    t.string "name", null: false
    t.datetime "revoked_at"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["folder_id"], name: "index_api_keys_on_folder_id"
    t.index ["key_digest"], name: "index_api_keys_on_key_digest", unique: true
    t.index ["user_id", "revoked_at"], name: "index_api_keys_on_user_id_and_revoked_at"
    t.index ["user_id"], name: "index_api_keys_on_user_id"
  end

  create_table "folders", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index "user_id, lower((name)::text)", name: "index_folders_on_user_id_and_lower_name", unique: true
    t.index ["user_id"], name: "index_folders_on_user_id"
  end

  create_table "oauth_access_grants", force: :cascade do |t|
    t.bigint "application_id", null: false
    t.string "code_challenge"
    t.string "code_challenge_method"
    t.datetime "created_at", null: false
    t.integer "expires_in", null: false
    t.text "redirect_uri", null: false
    t.string "resource"
    t.bigint "resource_owner_id", null: false
    t.datetime "revoked_at"
    t.string "scopes", default: "", null: false
    t.string "token", null: false
    t.index ["application_id"], name: "index_oauth_access_grants_on_application_id"
    t.index ["resource_owner_id"], name: "index_oauth_access_grants_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_grants_on_token", unique: true
  end

  create_table "oauth_access_tokens", force: :cascade do |t|
    t.bigint "application_id", null: false
    t.datetime "created_at", null: false
    t.integer "expires_in"
    t.datetime "last_used_at"
    t.string "refresh_token"
    t.string "resource"
    t.bigint "resource_owner_id"
    t.datetime "revoked_at"
    t.string "scopes"
    t.string "token", null: false
    t.index ["application_id"], name: "index_oauth_access_tokens_on_application_id"
    t.index ["refresh_token"], name: "index_oauth_access_tokens_on_refresh_token", unique: true
    t.index ["resource_owner_id"], name: "index_oauth_access_tokens_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_tokens_on_token", unique: true
  end

  create_table "oauth_applications", force: :cascade do |t|
    t.boolean "confidential", default: true, null: false
    t.datetime "created_at", null: false
    t.boolean "dynamic", default: false, null: false
    t.string "name", null: false
    t.text "redirect_uri", null: false
    t.string "scopes", default: "", null: false
    t.string "secret"
    t.string "uid", null: false
    t.datetime "updated_at", null: false
    t.index ["uid"], name: "index_oauth_applications_on_uid", unique: true
  end

  create_table "paste_views", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address_digest"
    t.bigint "paste_id", null: false
    t.text "referrer"
    t.string "source", null: false
    t.datetime "updated_at", null: false
    t.text "user_agent"
    t.bigint "user_id"
    t.index ["paste_id", "created_at"], name: "index_paste_views_on_paste_id_and_created_at"
    t.index ["paste_id"], name: "index_paste_views_on_paste_id"
    t.index ["source", "created_at"], name: "index_paste_views_on_source_and_created_at"
    t.index ["user_id"], name: "index_paste_views_on_user_id"
  end

  create_table "pastes", force: :cascade do |t|
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.string "custom_subdomain"
    t.bigint "folder_id"
    t.string "original_filename", null: false
    t.string "password_digest"
    t.string "title"
    t.string "token", null: false
    t.string "update_token_digest"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.integer "views_count", default: 0, null: false
    t.index "lower((custom_subdomain)::text)", name: "index_pastes_on_lower_custom_subdomain", unique: true, where: "(custom_subdomain IS NOT NULL)"
    t.index "lower((token)::text)", name: "index_pastes_on_lower_token"
    t.index ["folder_id"], name: "index_pastes_on_folder_id"
    t.index ["token"], name: "index_pastes_on_token", unique: true
    t.index ["user_id"], name: "index_pastes_on_user_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.text "user_agent"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index "lower((email_address)::text)", name: "index_users_on_lower_email_address", unique: true
  end

  add_foreign_key "api_keys", "folders"
  add_foreign_key "api_keys", "users"
  add_foreign_key "folders", "users"
  add_foreign_key "oauth_access_grants", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_access_grants", "users", column: "resource_owner_id"
  add_foreign_key "oauth_access_tokens", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_access_tokens", "users", column: "resource_owner_id"
  add_foreign_key "paste_views", "pastes"
  add_foreign_key "paste_views", "users"
  add_foreign_key "pastes", "folders"
  add_foreign_key "pastes", "users"
  add_foreign_key "sessions", "users"
end

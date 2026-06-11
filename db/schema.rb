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

ActiveRecord::Schema[8.1].define(version: 2026_06_10_234441) do
  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "batch_uploads", force: :cascade do |t|
    t.integer "completed_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.integer "failed_count", default: 0, null: false
    t.string "status", default: "pending", null: false
    t.integer "total_count", default: 0, null: false
    t.datetime "updated_at", null: false
  end

  create_table "label_reviews", force: :cascade do |t|
    t.string "app_abv"
    t.string "app_brand_name"
    t.string "app_class_type"
    t.string "app_country_of_origin"
    t.string "app_net_contents"
    t.string "app_producer"
    t.integer "batch_upload_id"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.text "extracted_fields"
    t.text "ocr_raw_text"
    t.text "results"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.string "verdict"
    t.index ["batch_upload_id"], name: "index_label_reviews_on_batch_upload_id"
    t.index ["status"], name: "index_label_reviews_on_status"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "label_reviews", "batch_uploads"
end

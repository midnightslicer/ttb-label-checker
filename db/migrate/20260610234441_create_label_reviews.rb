class CreateLabelReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :label_reviews do |t|
      t.references :batch_upload, null: true, foreign_key: true

      t.string :status, default: "pending", null: false

      # Application data — what the applicant claimed
      t.string :app_brand_name
      t.string :app_class_type
      t.string :app_abv
      t.string :app_net_contents
      t.string :app_producer
      t.string :app_country_of_origin

      # Output
      t.text   :extracted_fields
      t.text   :results
      t.string :verdict
      t.text   :error_message
      t.text   :ocr_raw_text

      t.timestamps
    end

    add_index :label_reviews, :status
  end
end

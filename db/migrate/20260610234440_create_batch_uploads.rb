class CreateBatchUploads < ActiveRecord::Migration[8.1]
  def change
    create_table :batch_uploads do |t|
      t.string  :status,          default: "pending", null: false
      t.integer :total_count,     default: 0,         null: false
      t.integer :completed_count, default: 0,         null: false
      t.integer :failed_count,    default: 0,         null: false

      t.timestamps
    end
  end
end

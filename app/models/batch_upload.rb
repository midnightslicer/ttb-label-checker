class BatchUpload < ApplicationRecord
  has_many :label_reviews, dependent: :destroy

  STATUSES = %w[pending processing complete failed partial].freeze

  scope :recent, -> { order(created_at: :desc) }

  def active?
    %w[pending processing].include?(status)
  end

  def progress_label
    "#{completed_count + failed_count} / #{total_count} complete"
  end

  # Recomputes the batch status from the per-review counters. Called by each
  # LabelAnalysisJob as it finishes so the batch reflects real-time progress.
  def update_status!
    if completed_count + failed_count >= total_count
      new_status = if failed_count == total_count
        "failed"
      elsif failed_count.positive?
        "partial"
      else
        "complete"
      end
      update!(status: new_status)
    else
      update!(status: "processing")
    end
  end
end

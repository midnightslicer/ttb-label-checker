class LabelAnalysisJob < ApplicationJob
  queue_as :default

  def perform(label_review_id)
    review = LabelReview.find(label_review_id)
    review.update!(status: "processing")

    extracted, raw = analyze(review)

    results = FieldComparator.call(review.application_data, extracted)

    review.update!(
      extracted_fields: extracted.to_json,
      ocr_raw_text:     raw,
      results:          results.to_json,
      verdict:          results[:verdict],
      status:           "complete"
    )

    finalize_batch(review, :completed_count)
  rescue OllamaService::ExtractionError => e
    review.update!(status: "failed", error_message: e.message)
    finalize_batch(review, :failed_count)
  end

  private

  # Runs the attached image through the vision model. Active Storage may store
  # the blob remotely, so download to a tempfile rather than assuming a path.
  # The image is preprocessed first to give the model cleaner edges to read.
  def analyze(review)
    review.label_image.blob.open do |file|
      processed = ImagePreprocessor.call(file.path)
      begin
        OllamaService.call(processed.path)
      ensure
        processed.close!
      end
    end
  end

  def finalize_batch(review, counter)
    return unless review.batch_upload_id

    batch = review.batch_upload
    batch.increment!(counter)
    batch.update_status!
  end
end

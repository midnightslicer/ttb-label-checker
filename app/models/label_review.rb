class LabelReview < ApplicationRecord
  belongs_to :batch_upload, optional: true
  has_one_attached :label_image

  STATUSES = %w[pending processing complete failed].freeze

  validates :label_image, presence: true

  scope :recent, -> { order(created_at: :desc) }

  def active?
    %w[pending processing].include?(status)
  end

  def complete?
    status == "complete"
  end

  def failed?
    status == "failed"
  end

  # Parsed results JSON, or nil if not yet analyzed.
  def results_data
    return nil if results.blank?

    @results_data ||= JSON.parse(results, symbolize_names: true)
  rescue JSON::ParserError
    nil
  end

  def extracted_data
    return nil if extracted_fields.blank?

    JSON.parse(extracted_fields)
  rescue JSON::ParserError
    nil
  end

  # The applicant-supplied fields keyed without the "app_" prefix, ready to
  # hand to FieldComparator.
  def application_data
    slice(
      "app_brand_name", "app_class_type", "app_abv",
      "app_net_contents", "app_producer", "app_country_of_origin"
    ).transform_keys { |k| k.delete_prefix("app_") }
  end
end

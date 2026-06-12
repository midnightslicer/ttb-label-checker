# Pure-Ruby comparison of applicant-supplied data against the fields the vision
# model extracted from the label. Returns the results JSON structure.
class FieldComparator
  GOVERNMENT_WARNING = (
    "GOVERNMENT WARNING: (1) According to the Surgeon General, women should not " \
    "drink alcoholic beverages during pregnancy because of the risk of birth defects. " \
    "(2) Consumption of alcoholic beverages impairs your ability to drive a car or " \
    "operate machinery, and may cause health problems."
  ).freeze

  # applicant field => extracted JSON key
  FIELD_MAP = {
    brand_name:        "brand_name",
    class_type:        "class_type",
    abv:               "abv",
    net_contents:      "net_contents",
    producer:          "producer",
    country_of_origin: "country_of_origin"
  }.freeze

  # Country of origin is optional on the application; don't penalize a blank.
  OPTIONAL_FIELDS = %i[country_of_origin].freeze

  # Fields compared by their leading numeric value rather than as text, so
  # "11" matches "11% BY VOL.".
  NUMERIC_FIELDS = %i[abv].freeze

  def self.call(app_data, extracted)
    new(app_data, extracted).call
  end

  def initialize(app_data, extracted)
    @app_data  = app_data
    @extracted = extracted
  end

  def call
    field_results = FIELD_MAP.map do |app_key, extracted_key|
      app_value   = @app_data[app_key.to_s].to_s
      label_value = @extracted[extracted_key].to_s
      result      = compare_field(app_key, app_value, label_value)

      {
        field:       app_key.to_s,
        app_value:   app_value,
        label_value: label_value,
        match:       result[:match],
        note:        result[:note]
      }
    end

    warning_result = compare_warning(@extracted["government_warning"].to_s)

    {
      fields:             field_results,
      government_warning: warning_result,
      verdict:            determine_verdict(field_results, warning_result)
    }
  end

  private

  def normalize(str)
    str.downcase.gsub(/[^\w\s\-\/]/, "").gsub(/\s+/, " ").strip
  end

  # Whitespace-insensitive form for containment checks, so the applicant's
  # "750 mL" is recognized inside the label's "NET CONT. 750ML".
  def compact(str)
    normalize(str).gsub(/\s+/, "")
  end

  # Leading numeric value of a string (e.g. "11% BY VOL." => 11.0), or nil.
  def numeric_value(str)
    match = str.match(/-?\d+(?:\.\d+)?/)
    match && match[0].to_f
  end

  def compare_field(app_key, app_value, label_value)
    if app_value.blank? && OPTIONAL_FIELDS.include?(app_key)
      return { match: true, note: "Not provided (optional)" }
    end
    return { match: false, note: "Not found on label" } if label_value.blank?
    return { match: false, note: "Not provided in application" } if app_value.blank?

    if NUMERIC_FIELDS.include?(app_key)
      app_num   = numeric_value(app_value)
      label_num = numeric_value(label_value)
      return { match: true, note: nil } if app_num && label_num && app_num == label_num
    end

    c_app   = compact(app_value)
    c_label = compact(label_value)

    if c_label.include?(c_app)
      # Exact match, or the label carries the full application value plus
      # standard TTB boilerplate ("NET CONT.", "PRODUCT OF", "% BY VOL.").
      { match: true, note: nil }
    elsif c_app.include?(c_label)
      { match: "fuzzy", note: "Label shows only part of the application value — review required" }
    else
      { match: false, note: %(Application says "#{app_value}" but label shows "#{label_value}") }
    end
  end

  def compare_warning(extracted_warning)
    normalized_extracted = extracted_warning.gsub(/\s+/, " ").strip
    normalized_required  = GOVERNMENT_WARNING.gsub(/\s+/, " ").strip

    present     = extracted_warning.present?
    exact_match = normalized_extracted == normalized_required
    has_prefix  = extracted_warning.start_with?("GOVERNMENT WARNING:")

    {
      present:     present,
      exact_match: exact_match,
      has_prefix:  has_prefix,
      note:        warning_note(present, exact_match, has_prefix)
    }
  end

  def warning_note(present, exact_match, has_prefix)
    return "Government warning not found on label" unless present
    return %("GOVERNMENT WARNING:" prefix missing or not in all-caps) unless has_prefix
    return nil if exact_match

    "Warning text present but does not exactly match required TTB language"
  end

  def determine_verdict(field_results, warning_result)
    return "reject" unless warning_result[:exact_match]
    return "reject" if field_results.any? { |f| f[:match] == false }
    return "needs_review" if field_results.any? { |f| f[:match] == "fuzzy" }

    "approve"
  end
end

# Compares applicant-supplied data against the fields the vision model extracted
# from the label and returns the results JSON structure.
#
# Deterministic string/number rules run first (the fast path). Semantic text
# fields that those rules can't cleanly resolve are escalated to SemanticMatcher,
# a small LLM that judges them against the full label transcription — this is how
# synonyms, boilerplate, and multi-party labels (importer vs bottler) get matched.
# The government warning stays fully deterministic.
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

  # Semantic text fields that may be escalated to the LLM matcher when the
  # deterministic checks don't produce a clean match. Quantitative fields (abv,
  # net_contents) stay code-only — exact rules beat an LLM there.
  LLM_FIELDS = %i[brand_name class_type producer country_of_origin].freeze

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

    apply_semantic_matches(field_results)

    warning_result = compare_warning(@extracted["government_warning"].to_s, @extracted["full_text"].to_s)

    {
      fields:             field_results,
      government_warning: warning_result,
      verdict:            determine_verdict(field_results, warning_result)
    }
  end

  private

  # Resolve the semantic fields the structured comparison couldn't clear, using
  # the full label transcription. First deterministically: the application value
  # often appears verbatim somewhere in full_text even when the structured field
  # captured a different candidate (e.g. the importer line vs the bottler line).
  # Only the genuinely fuzzy remainder (abbreviations, reordering, synonyms) is
  # escalated to the LLM matcher. Results are overwritten in place.
  def apply_semantic_matches(field_results)
    label_text = @extracted["full_text"].to_s
    return if label_text.blank?

    candidates = field_results.select do |f|
      LLM_FIELDS.include?(f[:field].to_sym) && f[:match] != true && f[:app_value].present?
    end
    return if candidates.empty?

    compact_label = compact(label_text)
    candidates.reject! do |f|
      next false unless compact_label.include?(compact(f[:app_value]))

      f[:match]       = true
      f[:label_value] = snippet_for(label_text, f[:app_value]) || f[:label_value]
      f[:note]        = nil
      true
    end
    return if candidates.empty?

    apply_llm_matches(label_text, candidates)
  end

  def apply_llm_matches(label_text, candidates)
    items = candidates.map do |f|
      { field: f[:field], app_value: f[:app_value], label_value: f[:label_value] }
    end
    verdicts = SemanticMatcher.call(label_text, items)

    candidates.each do |f|
      verdict = verdicts[f[:field]]
      next unless verdict

      f[:match]       = verdict[:match]
      f[:label_value] = verdict[:label_value].presence || f[:label_value]
      f[:note]        = verdict[:note]
    end
  rescue SemanticMatcher::MatchError
    nil # keep the deterministic results when the matcher can't run
  end

  # The original-formatting snippet of full_text that spans the application value
  # (first word ... last word), for display in the results table.
  def snippet_for(label_text, app_value)
    words = app_value.split(/\s+/).map { |w| w.gsub(/[^\w]/, "") }.reject { |w| w.length < 2 }
    return nil if words.empty?

    re = /#{Regexp.escape(words.first)}.{0,90}?#{Regexp.escape(words.last)}/i
    label_text.match(re)&.to_s
  end

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

  # Checked against both the dedicated government_warning field and the full label
  # transcription: the vision model sometimes drops the heading from the structured
  # field while keeping it verbatim in full_text (or vice versa), so either source
  # satisfying the requirement counts.
  def compare_warning(extracted_warning, full_text)
    normalized_required = GOVERNMENT_WARNING.gsub(/\s+/, " ").strip.downcase
    sources = [ extracted_warning, full_text ].map { |s| s.to_s.gsub(/\s+/, " ").strip }

    # Compare case-insensitively: TTB mandates the wording, not the casing, and
    # real labels routinely print the whole warning in all-caps. The required text
    # may be a substring of full_text, so accept containment as well as equality.
    present     = sources.any? { |s| s.match?(/government warning/i) }
    exact_match = sources.any? { |s| s.downcase.include?(normalized_required) }
    has_prefix  = sources.any? { |s| s.match?(/GOVERNMENT WARNING:/i) }

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

require "test_helper"

class FieldComparatorTest < ActiveSupport::TestCase
  # A complete, internally-consistent label/application pair. Individual tests
  # override just the fields they exercise so no unrelated field forces an
  # escalation to the LLM matcher (keeping these tests hermetic / network-free).
  def base_app
    {
      "brand_name"        => "Stone's Throw",
      "class_type"        => "IPA",
      "abv"               => "7",
      "net_contents"      => "500 mL",
      "producer"          => "Stone's Throw Brewing, Boulder, CO",
      "country_of_origin" => ""
    }
  end

  def base_extracted
    {
      "brand_name"         => "STONE'S THROW",
      "class_type"         => "IPA",
      "abv"                => "7% ABV",
      "net_contents"       => "500ML",
      "producer"           => "STONE'S THROW BREWING BOULDER CO",
      "country_of_origin"  => nil,
      "government_warning" => FieldComparator::GOVERNMENT_WARNING,
      "full_text"          => "STONE'S THROW BREWING IPA 7% ABV 500ML BOULDER CO " \
                              "#{FieldComparator::GOVERNMENT_WARNING}"
    }
  end

  def field(result, name)
    result[:fields].find { |f| f[:field] == name }
  end

  test "case- and punctuation-insensitive brand match (STONE'S THROW vs Stone's Throw)" do
    result = FieldComparator.call(base_app, base_extracted)
    assert_equal true, field(result, "brand_name")[:match]
  end

  test "ABV matches by leading numeric value across formatting" do
    app       = base_app.merge("abv" => "45")
    extracted = base_extracted.merge("abv" => "45% Alc./Vol. (90 Proof)")
    result    = FieldComparator.call(app, extracted)
    assert_equal true, field(result, "abv")[:match]
  end

  test "net contents matches despite whitespace and boilerplate" do
    app       = base_app.merge("net_contents" => "750 mL")
    extracted = base_extracted.merge("net_contents" => "NET CONT. 750ML")
    result    = FieldComparator.call(app, extracted)
    assert_equal true, field(result, "net_contents")[:match]
  end

  test "blank optional field (country_of_origin) passes without penalty" do
    result = FieldComparator.call(base_app, base_extracted)
    coo    = field(result, "country_of_origin")
    assert_equal true, coo[:match]
    assert_equal "Not provided (optional)", coo[:note]
  end

  test "blank required field is a mismatch" do
    app    = base_app.merge("class_type" => "")
    result = FieldComparator.call(app, base_extracted)
    ct     = field(result, "class_type")
    assert_equal false, ct[:match]
    assert_equal "Not provided in application", ct[:note]
  end

  test "field absent from the label is a mismatch" do
    # Blank full_text short-circuits semantic escalation, so the deterministic
    # verdict stands without any network call to the LLM matcher.
    extracted = base_extracted.merge("class_type" => "", "full_text" => "")
    result    = FieldComparator.call(base_app, extracted)
    ct        = field(result, "class_type")
    assert_equal false, ct[:match]
    assert_equal "Not found on label", ct[:note]
  end

  test "full_text containment rescues a structured-field miss" do
    # The structured producer field captured the wrong party, but the applicant's
    # value appears (contiguously) in the full transcription, so the deterministic
    # containment check rescues it without ever reaching the LLM matcher.
    extracted = base_extracted.merge(
      "producer"  => "SOME IMPORTER LLC",
      "full_text" => "STONE'S THROW BREWING, BOULDER, CO #{FieldComparator::GOVERNMENT_WARNING}"
    )
    result = FieldComparator.call(base_app, extracted)
    assert_equal true, field(result, "producer")[:match]
  end

  test "partial value yields a fuzzy verdict" do
    app       = base_app.merge("net_contents" => "750 milliliters")
    extracted = base_extracted.merge("net_contents" => "750")
    result    = FieldComparator.call(app, extracted)
    assert_equal "fuzzy", field(result, "net_contents")[:match]
  end

  # --- Government warning -------------------------------------------------

  test "exact warning text passes (case-insensitive)" do
    result = FieldComparator.call(base_app, base_extracted)
    gw     = result[:government_warning]
    assert gw[:present]
    assert gw[:exact_match]
    assert_nil gw[:note]
  end

  test "missing warning is flagged" do
    extracted = base_extracted.merge("government_warning" => "", "full_text" => "STONE'S THROW BREWING IPA")
    gw        = FieldComparator.call(base_app, extracted)[:government_warning]
    refute gw[:present]
    assert_equal "Government warning not found on label", gw[:note]
  end

  test "altered warning wording fails the exact check" do
    altered   = "GOVERNMENT WARNING: (1) According to the Surgeon General, do not drink while pregnant."
    extracted = base_extracted.merge("government_warning" => altered, "full_text" => altered)
    gw        = FieldComparator.call(base_app, extracted)[:government_warning]
    assert gw[:present]
    assert gw[:has_prefix]
    refute gw[:exact_match]
    assert_equal "Warning text present but does not exactly match required TTB language", gw[:note]
  end

  test "warning satisfied via full_text when structured field drops it" do
    extracted = base_extracted.merge("government_warning" => "")
    gw        = FieldComparator.call(base_app, extracted)[:government_warning]
    assert gw[:exact_match]
  end

  # --- Verdict ------------------------------------------------------------

  test "all fields matching with exact warning approves" do
    assert_equal "approve", FieldComparator.call(base_app, base_extracted)[:verdict]
  end

  test "any hard mismatch rejects" do
    # Blank full_text keeps the deterministic class_type mismatch from escalating.
    extracted = base_extracted.merge("class_type" => "Stout", "full_text" => "")
    assert_equal "reject", FieldComparator.call(base_app, extracted)[:verdict]
  end

  test "a fuzzy field with no mismatches needs review" do
    app       = base_app.merge("net_contents" => "750 milliliters")
    extracted = base_extracted.merge("net_contents" => "750")
    assert_equal "needs_review", FieldComparator.call(app, extracted)[:verdict]
  end

  test "non-exact warning rejects even when every field matches" do
    extracted = base_extracted.merge("government_warning" => "GOVERNMENT WARNING: drink responsibly", "full_text" => "GOVERNMENT WARNING: drink responsibly")
    assert_equal "reject", FieldComparator.call(base_app, extracted)[:verdict]
  end
end

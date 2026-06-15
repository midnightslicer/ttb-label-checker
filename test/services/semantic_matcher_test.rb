require "test_helper"

# Covers the pure response-parsing and prompt-building logic. The HTTP call to
# Ollama is intentionally not exercised here (it has no deterministic output);
# FieldComparator's own tests cover graceful degradation when the matcher fails.
class SemanticMatcherTest < ActiveSupport::TestCase
  def parse(raw)
    SemanticMatcher.new("label text", []).send(:parse, raw)
  end

  test "maps verdict strings to FieldComparator's match values" do
    raw = <<~JSON
      [
        {"field": "brand_name", "verdict": "match", "evidence": "Stone's Throw", "note": ""},
        {"field": "producer", "verdict": "fuzzy", "evidence": "Stone's", "note": "partial"},
        {"field": "class_type", "verdict": "mismatch", "evidence": "", "note": "absent"}
      ]
    JSON
    result = parse(raw)

    assert_equal true, result["brand_name"][:match]
    assert_equal "Stone's Throw", result["brand_name"][:label_value]
    assert_nil result["brand_name"][:note]

    assert_equal "fuzzy", result["producer"][:match]
    assert_equal "partial", result["producer"][:note]

    assert_equal false, result["class_type"][:match]
  end

  test "strips markdown code fences before parsing" do
    raw = %(```json\n[{"field": "brand_name", "verdict": "match", "evidence": "ACME", "note": ""}]\n```)
    result = parse(raw)
    assert_equal true, result["brand_name"][:match]
  end

  test "skips rows with unknown verdicts or blank fields" do
    raw = <<~JSON
      [
        {"field": "brand_name", "verdict": "maybe", "evidence": "x", "note": ""},
        {"field": "", "verdict": "match", "evidence": "x", "note": ""}
      ]
    JSON
    assert_empty parse(raw)
  end

  test "build_prompt enumerates each item as a question" do
    items   = [ { field: "brand_name", app_value: "Stone's Throw", label_value: "" } ]
    matcher = SemanticMatcher.new("full label text", items)
    prompt  = matcher.send(:build_prompt)

    assert_includes prompt, "full label text"
    assert_includes prompt, %(field "brand_name": is "Stone's Throw" present)
  end

  test "empty item list returns no verdicts without calling the model" do
    assert_empty SemanticMatcher.call("any label", [])
  end
end

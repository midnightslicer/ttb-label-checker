# Uses a small local text model to judge whether applicant-supplied field values
# are supported by the actual text on a label. This handles the cases pure-string
# logic can't: synonyms, abbreviations, reordering, boilerplate framing, and —
# crucially — labels that list several candidates (e.g. an importer AND a bottler)
# where the structured extraction captured the wrong one. The matcher sees the
# full label transcription, so it can find the right text regardless.
#
# FieldComparator only calls this for fields its deterministic checks could not
# cleanly resolve, so the model runs on the hard cases, not every field.
class SemanticMatcher
  class MatchError < StandardError; end

  SYSTEM_PROMPT = <<~PROMPT.strip
    You are a JSON API that checks alcohol-label applications against the label.
    You return structured JSON only. Begin your response with [ and end with ].
    Do not use markdown or code fences.
  PROMPT

  PROMPT_TEMPLATE = <<~PROMPT.strip
    Here is the complete text printed on an alcohol label:
    ---
    %<label_text>s
    ---

    For each item below, decide whether the application value is PRESENT on the
    label. Read the whole label — it often lists several parties (importer,
    producer, bottler) and several names, and the value may appear anywhere.

    Rules:
    - "match": the label contains the value's information — the name and any
      place/address — allowing for differences in case, punctuation, word order,
      abbreviations, and extra surrounding words. Other unrelated names on the
      label do not matter. If the exact words of the value appear on the label,
      it is a match.
    - "fuzzy": only part of the value appears, or it is genuinely ambiguous.
    - "mismatch": the value does not appear on the label at all, or the label
      states something that contradicts it (a different company, place, or number).

    Items:
    %<items>s

    Return a JSON array. For each item return an object:
    {"field": "<field>", "verdict": "match" | "fuzzy" | "mismatch",
     "evidence": "<the exact snippet from the label that supports your verdict, or empty>",
     "note": "<short reason, or empty when it is a clean match>"}
  PROMPT

  VERDICT_MAP = { "match" => true, "fuzzy" => "fuzzy", "mismatch" => false }.freeze

  # items: array of { field:, app_value:, label_value: }
  # Returns a Hash keyed by field name => { match:, label_value:, note: }.
  def self.call(label_text, items)
    new(label_text, items).call
  end

  def initialize(label_text, items)
    @label_text = label_text.to_s
    @items      = items
  end

  def call
    return {} if @items.empty?

    response = connection.post("/api/generate") do |req|
      req.body = {
        model:   ENV.fetch("MATCH_MODEL", "gemma3:4b"),
        system:  SYSTEM_PROMPT,
        prompt:  build_prompt,
        stream:  false,
        options: { num_predict: 500, temperature: 0 }
      }
    end

    parse(response.body["response"].to_s)
  rescue Faraday::Error, JSON::ParserError => e
    raise MatchError, "Semantic match failed: #{e.message}"
  end

  private

  def build_prompt(template = PROMPT_TEMPLATE)
    items = @items.each_with_index.map do |item, i|
      %(#{i + 1}. field "#{item[:field]}": is "#{item[:app_value]}" present on the label?)
    end.join("\n")

    format(template, label_text: @label_text, items: items)
  end

  def parse(raw)
    json = raw.strip.gsub(/\A```(?:json)?\s*/, "").gsub(/\s*```\z/, "").strip
    rows = JSON.parse(json)

    rows.each_with_object({}) do |row, out|
      field = row["field"].to_s
      next if field.blank? || !VERDICT_MAP.key?(row["verdict"])

      out[field] = {
        match:       VERDICT_MAP.fetch(row["verdict"]),
        label_value: row["evidence"].to_s.strip,
        note:        row["note"].to_s.strip.presence
      }
    end
  end

  def connection
    Faraday.new(url: ENV.fetch("OLLAMA_URL", "http://localhost:11434")) do |f|
      f.request :json
      f.response :json
      f.request :retry, max: 2, interval: 1
      f.options.timeout = ENV.fetch("OLLAMA_TIMEOUT", 120).to_i
    end
  end
end

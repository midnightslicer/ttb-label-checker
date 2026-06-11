# Sends a label image to the local Ollama vision model and returns the
# extracted fields as a normalized Hash (string keys).
class OllamaService
  class ExtractionError < StandardError; end

  SYSTEM_PROMPT = <<~PROMPT.strip
    You are a JSON extraction API. You receive alcohol label images and return
    structured JSON only. Your response must begin with { and end with }.
    Do not use markdown. Do not use code fences.
  PROMPT

  USER_PROMPT = <<~PROMPT.strip
    Extract these fields from the label. Return null for missing fields.
    Normalize all whitespace to single spaces.

    For "government_warning", transcribe the complete warning paragraph exactly as
    printed, including the leading "GOVERNMENT WARNING:" heading if it appears.

    {"brand_name": null, "class_type": null, "abv": null, "net_contents": null,
    "producer": null, "country_of_origin": null, "government_warning": null}
  PROMPT

  def self.call(image_path)
    new.call(image_path)
  end

  def call(image_path)
    image_data = Base64.strict_encode64(File.binread(image_path))

    response = connection.post("/api/generate") do |req|
      req.body = {
        model:   ENV.fetch("OLLAMA_MODEL", "gemma3:12b"),
        system:  SYSTEM_PROMPT,
        prompt:  USER_PROMPT,
        stream:  false,
        options: { num_predict: 400, temperature: 0 },
        images:  [image_data]
      }
    end

    raw = response.body["response"].to_s.strip
    # Strip markdown fences defensively — the model may ignore instructions.
    raw = raw.gsub(/\A```(?:json)?\s*/, "").gsub(/\s*```\z/, "").strip

    parsed = JSON.parse(raw)
    [normalize_whitespace(parsed), raw]
  rescue JSON::ParserError, Faraday::Error => e
    raise ExtractionError, "Ollama extraction failed: #{e.message}"
  end

  private

  def connection
    Faraday.new(url: ENV.fetch("OLLAMA_URL", "http://localhost:11434")) do |f|
      f.request :json
      f.response :json
      f.request :retry, max: 2, interval: 1
      f.options.timeout = ENV.fetch("OLLAMA_TIMEOUT", 120).to_i
    end
  end

  def normalize_whitespace(extracted)
    extracted.transform_values do |v|
      v.is_a?(String) ? v.gsub(/\s+/, " ").strip : v
    end
  end
end

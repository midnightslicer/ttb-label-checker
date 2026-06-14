# Sends a label image to the local Ollama vision model and returns the
# extracted fields as a normalized Hash (string keys).
class OllamaService
  class ExtractionError < StandardError; end

  # Raised internally when Ollama returns a 200 with an empty body — a transient
  # glitch the Faraday retry middleware doesn't catch (it only retries transport
  # errors). Retried in #call.
  class EmptyResponseError < StandardError; end

  # Total attempts for transient failures (empty or unparseable response).
  MAX_ATTEMPTS = 3

  SYSTEM_PROMPT = <<~PROMPT.strip
    You are a JSON extraction API. You receive alcohol label images and return
    structured JSON only. Your response must begin with { and end with }.
    Do not use markdown. Do not use code fences.
  PROMPT

  USER_PROMPT = <<~PROMPT.strip
    Extract these fields from the label. Return null for missing fields.
    Normalize all whitespace to single spaces.

    For "government_warning", transcribe the warning verbatim and you MUST keep its
    heading. U.S. labels print the heading "GOVERNMENT WARNING:" (often bold or in
    caps) immediately before the numbered text — treat it as the first words of the
    warning, not a separate title, and never omit it. Whenever those words appear,
    the value must begin with "GOVERNMENT WARNING:". For example:
    "GOVERNMENT WARNING: (1) According to the Surgeon General, women should not ..."

    For "full_text", transcribe ALL text printed anywhere on the label, verbatim,
    including every producer/importer/bottler line and address, as a single string.
    Do not summarize or omit small print.

    {"brand_name": null, "class_type": null, "abv": null, "net_contents": null,
    "producer": null, "country_of_origin": null, "government_warning": null,
    "full_text": null}
  PROMPT

  def self.call(image_path)
    new.call(image_path)
  end

  def call(image_path)
    image_data = Base64.strict_encode64(File.binread(image_path))

    attempts = 0
    begin
      attempts += 1
      raw = request_extraction(image_data)
      raise EmptyResponseError, "empty response body" if raw.blank?

      parsed = JSON.parse(raw)
      [ normalize_whitespace(parsed), raw ]
    rescue EmptyResponseError, JSON::ParserError => e
      retry if attempts < MAX_ATTEMPTS

      raise ExtractionError, "Ollama extraction failed after #{attempts} attempts: #{e.message}"
    rescue Faraday::Error => e
      raise ExtractionError, "Ollama extraction failed: #{e.message}"
    end
  end

  private

  # Posts the image and returns the model's response text, with any stray markdown
  # fences stripped. May be blank when the model glitches.
  def request_extraction(image_data)
    response = connection.post("/api/generate") do |req|
      req.body = {
        model:   ENV.fetch("OLLAMA_MODEL", "gemma3:12b"),
        system:  SYSTEM_PROMPT,
        prompt:  USER_PROMPT,
        stream:  false,
        options: { num_predict: 700, temperature: 0 },
        images:  [ image_data ]
      }
    end

    response.body["response"].to_s.strip
      .gsub(/\A```(?:json)?\s*/, "").gsub(/\s*```\z/, "").strip
  end

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

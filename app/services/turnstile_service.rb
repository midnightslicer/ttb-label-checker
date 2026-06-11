# Server-side verification of a Cloudflare Turnstile token.
#
# Turnstile is considered "enabled" only when both site and secret keys are
# present. When unset (e.g. local development) verification is skipped so the
# app remains usable without Cloudflare configured.
class TurnstileService
  VERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify".freeze

  def self.enabled?
    site_key.present? && secret_key.present?
  end

  def self.site_key
    ENV["TURNSTILE_SITE_KEY"].presence
  end

  def self.secret_key
    ENV["TURNSTILE_SECRET_KEY"].presence
  end

  # Returns true when the challenge passes (or when Turnstile is disabled).
  def self.verify(token, remote_ip: nil)
    return true unless enabled?
    return false if token.blank?

    response = Faraday.post(VERIFY_URL, {
      secret:   secret_key,
      response: token,
      remoteip: remote_ip
    }.compact)

    body = JSON.parse(response.body)
    body["success"] == true
  rescue Faraday::Error, JSON::ParserError
    false
  end
end

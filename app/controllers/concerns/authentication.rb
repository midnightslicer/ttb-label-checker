# Lightweight session-based gate for the whole app. Credentials come from
# AUTH_USERNAME / AUTH_PASSWORD env vars; the login form is additionally
# protected by a Cloudflare Turnstile challenge (see SessionsController).
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    # Allow a controller to opt specific actions out of the auth gate.
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private

  def authenticated?
    session[:authenticated] == true
  end

  def require_authentication
    return if authenticated?

    session[:return_to] = request.fullpath if request.get_or_head?
    redirect_to login_path
  end

  def self.credentials_valid?(username, password)
    expected_user = ENV.fetch("AUTH_USERNAME", "admin")
    expected_pass = ENV.fetch("AUTH_PASSWORD", "password")

    ActiveSupport::SecurityUtils.secure_compare(username.to_s, expected_user) &
      ActiveSupport::SecurityUtils.secure_compare(password.to_s, expected_pass)
  end
end

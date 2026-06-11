class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[new create]

  # Redirect away from the login page if already signed in.
  before_action :redirect_if_authenticated, only: %i[new create]

  def new
  end

  def create
    unless TurnstileService.verify(params["cf-turnstile-response"], remote_ip: request.remote_ip)
      flash.now[:alert] = "Please complete the verification challenge and try again."
      return render :new, status: :unprocessable_entity
    end

    if Authentication.credentials_valid?(params[:username], params[:password])
      reset_session
      session[:authenticated] = true
      redirect_to(session.delete(:return_to) || root_path, notice: "Signed in.")
    else
      flash.now[:alert] = "Invalid username or password."
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    reset_session
    redirect_to login_path, notice: "Signed out."
  end

  private

  def redirect_if_authenticated
    redirect_to root_path if authenticated?
  end
end

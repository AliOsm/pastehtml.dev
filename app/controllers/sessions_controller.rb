class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]

  rate_limit to: 10, within: 3.minutes, only: :create,
    with: -> { redirect_to new_session_path, alert: t("sessions.rate_limited") }

  def new
    redirect_to pastes_path if authenticated?
  end

  def create
    if user = User.authenticate_by(email_address: params[:email_address], password: params[:password])
      start_new_session_for user
      redirect_to after_authentication_url, status: :see_other, notice: t("sessions.signed_in")
    else
      redirect_to new_session_path(email_address: params[:email_address]), alert: t("sessions.invalid")
    end
  end

  def destroy
    terminate_session
    redirect_to root_path, status: :see_other, notice: t("sessions.signed_out")
  end
end

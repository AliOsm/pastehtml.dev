class UsersController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]

  rate_limit to: 20, within: 1.hour, only: :create,
    with: -> { redirect_to new_user_path, alert: t("users.rate_limited") }

  def new
    return redirect_to pastes_path if authenticated?

    @user = User.new(email_address: params[:email_address])
  end

  def create
    return redirect_to pastes_path if authenticated?

    @user = User.new(user_params)

    if @user.save
      start_new_session_for @user
      redirect_to after_authentication_url, status: :see_other, notice: t("users.created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  private
    def user_params
      params.require(:user).permit(:email_address, :password, :password_confirmation)
    end
end
